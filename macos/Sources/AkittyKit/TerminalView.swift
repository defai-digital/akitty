import AppKit
import CoreText
import MetalKit
import QuartzCore
import os

@MainActor public final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    private var sessionStorage: TerminalSession?
    public var session: TerminalSession { sessionStorage! }
    public var onExit: (() -> Void)?
    private var exitHandled = false
    public private(set) var snapshot: Snapshot?
    public private(set) var health = RendererHealth()
    public var onStatus: ((String) -> Void)?
    public var onTitle: ((String) -> Void)?
    var onChrome: ((ChromeDocument?) -> Void)?
    private var presenter: MetalPresenter?
    private var bitmap: CGContext?
    private let snapshotQueue = DispatchQueue(label: "com.defai.akitty.snapshot", qos: .userInteractive)
    private let rasterQueue = DispatchQueue(label: "com.defai.akitty.raster", qos: .userInteractive)
    /// Keeps the bitmap between frames; only touched on `rasterQueue`.
    private let rasterizer = GridRasterizer()
    /// Whether the last frame went through the layered Metal path.
    private var lastLayered = false
    /// Grid rows changed since the last raster started; nil means unknown (repaint everything).
    private var pendingDamage: Set<Int>? = nil
    private var pollInFlight = false
    private var rasterInFlight = false
    private var rasterPending = false
    private let imageStore = ImageStore()
    private var lastCellPixels: (Int, Int) = (0, 0)
    private var timer: Timer?
    /// Polls at the display rate while frames move; paused, not invalidated, while the view is idle.
    private var refreshLink: CADisplayLink?
    /// Uptime seconds of the last changed snapshot or local input. Output, typing and graphics alike keep the
    /// display-rate poll going for a second, so an echoed keystroke or a scrolling screen never waits for the 30 Hz tick.
    private var lastChange: Double = 0
    private var composition = Composition()
    private var tracking: NSTrackingArea?
    private var selectionStart: (Int, Int)?
    private var selectionEnd: (Int, Int)?
    private var selectedText = ""
    private var pendingClipboard: [String] = []
    private var clipboardPromptOpen = false
    private var lastBell = Date.distantPast
    private var lastGrid: (Int, Int) = (0, 0)
    /// Key codes whose press went out as a Kitty escape, so only those get a release.
    private var kittyDown: [UInt16: KittyKeyInput] = [:]
    /// Physical modifier keys currently down; a flags change alone cannot say which one moved.
    private var heldModifierKeys: Set<UInt16> = []
    private var stopped = false
    private let shutdownGroup = DispatchGroup()
    private var fontSize: CGFloat = 14
    private var preferences = TerminalPreferences.load()
    private var cachedFont: (name: String, size: CGFloat, font: NSFont, cell: CGSize)?
    private var fontLayout: (name: String, size: CGFloat, font: NSFont, cell: CGSize) {
        if let cachedFont, cachedFont.name == preferences.fontName, cachedFont.size == fontSize { return cachedFont }
        let size = fontSize.isFinite ? min(36, max(9, fontSize)) : 14
        let font = (preferences.fontName == "System Monospaced" ? nil : NSFont(name: preferences.fontName, size: size))
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        // NSString.size(withAttributes:) raised an uncaught CoreText dictionary exception during
        // redraw on macOS 27. A fixed grid needs a glyph advance, not attributed-string layout.
        let face = font as CTFont
        var character: UniChar = 0x4d, glyph: CGGlyph = 0
        let found = CTFontGetGlyphsForCharacters(face, &character, &glyph, 1)
        var advance = CGSize.zero
        if found { CTFontGetAdvancesForGlyphs(face, .horizontal, &glyph, &advance, 1) }
        let width = advance.width.isFinite && advance.width > 0 ? advance.width : size * 0.6
        let height = CTFontGetAscent(face) + CTFontGetDescent(face) + CTFontGetLeading(face) + 4
        let cell = CGSize(width: ceil(min(256, max(1, width))),
                          height: ceil(min(512, max(1, height.isFinite && height > 0 ? height : size + 4))))
        let result = (name: preferences.fontName, size: fontSize, font: font, cell: cell)
        cachedFont = result
        return result
    }
    private var font: NSFont { fontLayout.font }
    public var cellSize: CGSize { fontLayout.cell }
    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }
    /// `directory` overrides the Settings starting directory for this terminal only (a folder opened from Finder, Dock or `open -a`).
    public convenience init(headless: Bool = false, forceSoftware: Bool = false, forceShaderFailure: Bool = false, directory: String? = nil) throws {
        var initial = TerminalPreferences.load()
        if let directory { initial.directory = directory }
        try self.init(headless: headless, forceSoftware: forceSoftware, forceShaderFailure: forceShaderFailure, initial: initial)
    }
    init(headless: Bool, forceSoftware: Bool, forceShaderFailure: Bool, initial: TerminalPreferences) throws {
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        // NSView must be initialized before a throwing operation can unwind it.
        let integrationDirectory: String?
        if initial.shellIntegration && !headless {
            guard let resources = Bundle.main.resourceURL else { throw AkittyError.core("Shell integration resources missing") }
            integrationDirectory = resources.appendingPathComponent("shell-integration").path
        } else { integrationDirectory = nil }
        sessionStorage = try TerminalSession(headless: headless, shell: initial.shell, directory: initial.directory, scrollback: initial.scrollback, shellIntegrationDirectory: integrationDirectory)
        preferences = initial; fontSize = initial.fontSize
        try syncProgramChrome()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .terminalPreferencesChanged, object: nil)
        registerForDraggedTypes([.fileURL, .string])
        wantsLayer = true
        do {
            let renderer = try MetalPresenter(forceFailure: forceSoftware || ProcessInfo.processInfo.environment["AKITTY_FORCE_METAL_UNAVAILABLE"] == "1", forceShaderFailure: forceShaderFailure)
            renderer.onFailure = { [weak self] message in self?.renderFailed(message) }
            presenter = renderer
            renderer.view.autoresizingMask = [.width, .height]
            renderer.view.frame = bounds
            addSubview(renderer.view)
        } catch { renderFailed(error.localizedDescription) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(timer!, forMode: .common)
        // The 30 Hz timer stays the idle fallback; the display link only adds polls while frames move.
        setAccessibilityIdentifier("akitty-terminal")
    }
    required init?(coder: NSCoder) { nil }
    deinit { timer?.invalidate(); refreshLink?.invalidate(); NotificationCenter.default.removeObserver(self) }
    @objc private func preferencesChanged() {
        // A stopped terminal has no session behind it; a late notification must not surface an error.
        guard !stopped else { return }
        preferences = TerminalPreferences.load(); fontSize = preferences.fontSize
        do { try syncProgramChrome() } catch { show(error) }
        // Fonts changed, so cell metrics and CJK glyphs may differ; repaint every row.
        pendingDamage = nil
        resizeTerminal(); redraw()
    }
    public func shutdown(completion: @escaping @Sendable () -> Void = {}) {
        if !stopped {
            stopped = true
            timer?.invalidate(); timer = nil
            stopRefreshLink()
            pendingClipboard.removeAll()
            let cleanup = session.prepareClose(), group = shutdownGroup
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do { try cleanup?() } catch { Logger(subsystem: "com.defai.akitty", category: "pty").error("PTY close failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        // A second caller (for example Quit during window close) waits for the same cleanup.
        shutdownGroup.notify(queue: .global(qos: .userInitiated), execute: completion)
    }
    public override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The display link belongs to the view's display, so it is dropped with the window.
        if window == nil { stopRefreshLink() } else { updatePolling() }
        resizeTerminal(); poll(); showClipboardRequest()
    }
    public override func layout() { super.layout(); presenter?.view.frame = bounds; resizeTerminal(); redraw() }
    // A new backing scale changes the cell's device-pixel size even when the grid does not change.
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resizeTerminal(); redraw() }
    private func resizeTerminal() {
        guard bounds.width > 20, bounds.height > 20, !stopped else { return }
        let cols = min(512, max(2, Int((bounds.width - 16) / cellSize.width)))
        let rows = min(256, max(1, min(32768 / cols, Int((bounds.height - 16) / cellSize.height))))
        // Programs sizing graphics ask for cell pixels (CSI 16 t); report device pixels.
        let scale = window?.backingScaleFactor ?? 2
        let pixels = (min(256, max(1, Int((cellSize.width * scale).rounded()))), min(512, max(1, Int((cellSize.height * scale).rounded()))))
        if pixels != lastCellPixels, (try? session.call("cell_size", ["width": pixels.0, "height": pixels.1])) != nil { lastCellPixels = pixels }
        guard lastGrid != (cols, rows) else { return }
        do { _ = try session.call("resize", ["cols": cols, "rows": rows]); lastGrid = (cols, rows) }
        catch { show(error) }
    }
    /// Display-rate polling pays off only while an animation runs or a frame changed within the last second.
    nonisolated static func wantsFastPolling(animating: Bool, changedAt: Double, now: Double) -> Bool {
        if animating { return true }
        return now - changedAt < 1
    }
    private func updatePolling() {
        setFastPolling(Self.wantsFastPolling(animating: snapshot?.animating == true, changedAt: lastChange, now: ProcessInfo.processInfo.systemUptime))
    }
    /// The link is only created inside a window; without one the idle timer keeps polling.
    private func setFastPolling(_ fast: Bool) {
        guard fast, !stopped, window != nil else { refreshLink?.isPaused = true; return }
        if refreshLink == nil {
            // The link retains its target, so it targets a weak proxy rather than the view itself.
            let link = displayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
            link.add(to: .main, forMode: .common)
            refreshLink = link
        }
        refreshLink?.isPaused = false
    }
    /// Whether the display link is polling now, rather than only the 30 Hz idle timer.
    var pollsAtDisplayRate: Bool { refreshLink?.isPaused == false }
    private func stopRefreshLink() { refreshLink?.invalidate(); refreshLink = nil }
    fileprivate func displayTick(_ link: CADisplayLink) {
        guard !stopped, window != nil else { link.isPaused = true; return }
        poll()
    }
    public func runAgentCommand(actor: String, command: String) async throws -> (lease: UInt64, dispatch: AgentDispatch) {
        guard let window else { throw AkittyError.core("Terminal must be in a window for command approval.") }
        let host = AgentCommandHost(session: session)
        return try await host.execute(actor: actor, command: command) { await AgentCommandHost.confirm($0, in: window) }
    }
    @objc public func reclaimAgentControl(_ sender: Any?) {
        do { try session.reclaimControl(); poll() } catch { show(error) }
    }
    public func poll() {
        guard !stopped, !pollInFlight else { return }
        pollInFlight = true
        let session = self.session, base = snapshot, since = snapshot?.revision, store = imageStore
        snapshotQueue.async { [weak self] in
            let result = Result { try session.snapshot(since: since, base: base) }
            // Pixels are fetched here, off the main thread, before the frame is drawn.
            if case let .success(.some(next)) = result { store.sync(next.images ?? [], session: session) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInFlight = false
                guard !self.stopped else { return }
                self.applySnapshot(result)
                self.updatePolling()
            }
        }
    }
    /// Applies a preference set the same way a settings change does, including the program-chrome switch.
    func applyPreferences(_ next: TerminalPreferences) {
        guard !stopped else { return }
        preferences = next; fontSize = next.fontSize
        do { try syncProgramChrome() } catch { show(error) }
        resizeTerminal(); redraw()
    }
    private func syncProgramChrome() throws {
        _ = try session.call("program_chrome", ["enabled": preferences.programChrome])
    }
    private func applySnapshot(_ result: Result<Snapshot?, Error>) {
        do {
            if let next = try result.get() {
                let previous = snapshot
                snapshot = next
                // The host owns the visible selection; without a drag selection, drop core marks
                // left over from a cleared selection (schema 1 has no deselect request).
                if selectionEnd == nil { snapshot?.clearSelectionMarks() }
                // More frames usually follow a changed one: output keeps streaming, an animation advances.
                lastChange = ProcessInfo.processInfo.systemUptime
                if next.exited, next.error == nil, next.exit_code == 0, !exitHandled {
                    exitHandled = true
                    DispatchQueue.main.async { [weak self] in self?.onExit?() }
                }
                if let error = next.error { onStatus?(error) }
                else if let failure = health.failure { onStatus?("Software rendering: \(failure)") }
                else if next.exited { onStatus?("Shell exited (\(next.exit_code.map(String.init) ?? "closed"))") }
                else if next.control?.agent == true { onStatus?("Controlled by \(next.control?.owner ?? "agent") · Edit → Reclaim Terminal Control") }
                else if let presentation = next.chrome?.presentation { onStatus?(presentation) }
                else { onStatus?("\(next.cols) cols × \(next.rows) rows") }
                onTitle?(next.title)
                onChrome?(next.chrome)
                // Clipboard replacement is latest-request-wins while another
                // prompt is open, keeping the approval queue bounded.
                if let text = next.clipboard.last { pendingClipboard = [text] }
                ringBell(next.bell == true)
                if next.partial == true, let dirty = next.dirty { pendingDamage?.formUnion(dirty) } else { pendingDamage = nil }
                redraw(imageOnly: Self.isImageOnlyUpdate(previous: previous, next: next))
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
            showClipboardRequest()
        } catch { show(error) }
    }
    private func renderFailed(_ message: String) {
        health.fail(message)
        presenter?.view.removeFromSuperview(); presenter = nil
        onStatus?("Software rendering: \(message)")
        Logger(subsystem: "com.defai.akitty", category: "renderer").error("Metal disabled: \(message, privacy: .public)")
        needsDisplay = true
    }
    /// A partial snapshot with no dirty rows and an identical cursor carries only image changes (a generation
    /// bump, placements moved, added or removed): the text layers are still valid, so no CPU raster is needed.
    nonisolated static func isImageOnlyUpdate(previous: Snapshot?, next: Snapshot) -> Bool {
        guard let previous, next.partial == true, let dirty = next.dirty, dirty.isEmpty,
              previous.cursor.row == next.cursor.row, previous.cursor.col == next.cursor.col,
              previous.cursor.visible == next.cursor.visible else { return false }
        return true
    }
    private func redraw(imageOnly: Bool = false) {
        guard let snapshot, bounds.width > 0, bounds.height > 0, !stopped else { return }
        // An image-only frame goes straight to the GPU: new placements and textures, redraw, no text work.
        if imageOnly, let presenter, presenter.layered, !(snapshot.images ?? []).isEmpty, pendingDamage == [], !rasterInFlight {
            do {
                try presenter.updateImages(placements: snapshot.images ?? [], pixels: imageStore.entries,
                                           grid: GridGeometry(cols: snapshot.cols, rows: snapshot.rows, cell: cellSize, scale: window?.backingScaleFactor ?? 2))
            } catch { renderFailed(error.localizedDescription) }
            return
        }
        if rasterInFlight { rasterPending = true; return }
        rasterInFlight = true; rasterPending = false
        let size = bounds.size, scale = window?.backingScaleFactor ?? 2
        let fontName = font.fontName, fontSize = font.pointSize, cells = cellSize, cjkFontName = preferences.cjkFont, marked = composition.text
        // With Metal, frames that show images split the text into two layers and let the GPU composite each image from
        // its own texture, so an animation frame re-uploads one texture instead of repainting the window. Frames without
        // images (and the software fallback) keep the single bitmap.
        let layered = presenter != nil && !(snapshot.images ?? []).isEmpty
        var damage = pendingDamage
        // The other path's retained bitmaps went stale while it was idle.
        if layered != lastLayered { damage = nil; lastLayered = layered }
        let rasterizer = self.rasterizer, images = layered ? [:] : imageStore.images
        // Reuse the bitmap only when the GPU path copies it out before the next frame starts drawing into it.
        let reuse = presenter != nil
        let grid = GridGeometry(cols: snapshot.cols, rows: snapshot.rows, cell: cells, scale: scale)
        pendingDamage = []
        rasterQueue.async { [weak self] in
            if layered {
                let result = Result { try rasterizer.renderLayers(snapshot: snapshot, damage: damage, size: size, scale: scale, fontName: fontName, fontSize: fontSize, cellSize: cells, composition: marked, cjkFontName: cjkFontName) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.rasterInFlight = false
                    guard !self.stopped else { return }
                    do {
                        let frame = try result.get()
                        if size == self.bounds.size, let presenter = self.presenter {
                            try presenter.updateLayers(background: frame.background, foreground: frame.foreground, damage: frame.damage, grid: grid,
                                                       placements: self.snapshot?.images ?? snapshot.images ?? [], pixels: self.imageStore.entries)
                        } else { self.pendingDamage = nil }
                    } catch { self.pendingDamage = nil; self.renderFailed(error.localizedDescription) }
                    if self.rasterPending { self.redraw() }
                }
                return
            }
            let result = Result { try rasterizer.render(snapshot: snapshot, damage: damage, size: size, scale: scale, fontName: fontName, fontSize: fontSize, cellSize: cells, composition: marked, cjkFontName: cjkFontName, images: images, reuse: reuse) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.rasterInFlight = false
                guard !self.stopped else { return }
                do {
                    let frame = try result.get()
                    if size == self.bounds.size {
                        self.bitmap = frame.context
                        if let presenter = self.presenter { do { try presenter.update(bitmap: frame.context, damage: frame.damage) } catch { self.renderFailed(error.localizedDescription) } }
                        self.needsDisplay = true
                    } else { self.pendingDamage = nil }
                } catch { self.pendingDamage = nil; self.renderFailed(error.localizedDescription) }
                if self.rasterPending { self.redraw() }
            }
        }
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard presenter == nil else { return }
        NSColor(calibratedRed: 8/255, green: 10/255, blue: 13/255, alpha: 1).setFill(); bounds.fill()
        if let image = bitmap?.makeImage(), let context = NSGraphicsContext.current?.cgContext {
            context.saveGState(); context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: bounds); context.restoreGState()
        }
    }
    /// One beep per second at most, so a program that rings in a loop cannot make noise continuously.
    private func ringBell(_ rang: Bool) {
        guard rang, Date().timeIntervalSince(lastBell) >= 1 else { return }
        lastBell = Date(); NSSound.beep()
    }
    private func show(_ error: Error) { onStatus?(error.localizedDescription); NSSound.beep() }
    public func send(_ text: String, paste: Bool = false) {
        guard !stopped else { return }
        do {
            try session.input(text, paste: paste)
            // The echo arrives within milliseconds; poll at the display rate to show it on the next frame.
            lastChange = ProcessInfo.processInfo.systemUptime
            updatePolling()
        } catch { show(error) }
    }
    /// Kitty keyboard protocol: bytes for this event when the running program asked for them.
    private func kittyKey(_ event: NSEvent, type: KittyEventType) -> KittyKeyResult {
        let flags = Int(snapshot?.kitty_flags ?? 0)
        guard flags != 0, !hasMarkedText(),
              let input = KittyKeyInput(event: event, optionAsAlt: preferences.optionAsAlt, type: type) else { return .legacy }
        // With "all keys as escape codes", plain text from an input method (Japanese, Chinese…) still has to compose.
        let plain = input.modifiers.subtracting([.shift, .capsLock, .numLock]).isEmpty
        if flags & KittyKeyEncoder.reportAllKeys != 0, plain, input.key != nil,
           inputContext?.selectedKeyboardInputSource?.hasPrefix("com.apple.keylayout.") == false { return .legacy }
        return KittyKeyEncoder.encode(input, flags: flags)
    }
    public override func keyUp(with event: NSEvent) {
        if kittyDown.removeValue(forKey: event.keyCode) != nil, case let .bytes(bytes) = kittyKey(event, type: .release) { send(String(decoding: bytes, as: UTF8.self)) }
        else { super.keyUp(with: event) }
    }
    public override func flagsChanged(with event: NSEvent) {
        let flags = Int(snapshot?.kitty_flags ?? 0)
        guard let modifier = KittyKeyEncoder.modifier(forKeyCode: event.keyCode) else { super.flagsChanged(with: event); return }
        // Per physical key: with both Shifts down, releasing one leaves the aggregate flag set. A key we
        // never saw go down (pressed before the view had focus) falls back to the aggregate state.
        let mods = KittyKeyInput.modifiers(of: event.modifierFlags, optionAsAlt: preferences.optionAsAlt)
        let pressed: Bool
        if heldModifierKeys.remove(event.keyCode) != nil { pressed = false }
        else { pressed = event.modifierFlags.contains(Self.nativeFlag(for: modifier)); if pressed { heldModifierKeys.insert(event.keyCode) } }
        guard flags & KittyKeyEncoder.reportAllKeys != 0, !hasMarkedText() else { super.flagsChanged(with: event); return }
        if case let .bytes(bytes) = KittyKeyEncoder.encodeModifier(keyCode: event.keyCode, modifiers: mods, pressed: pressed, flags: flags) {
            send(String(decoding: bytes, as: UTF8.self))
        }
    }
    private static func nativeFlag(for modifier: KittyModifiers) -> NSEvent.ModifierFlags {
        if modifier == .shift { return .shift }
        if modifier == .ctrl { return .control }
        if modifier == .alt { return .option }
        return .command
    }
    /// Keys still held when focus leaves would never see their key-up here, so release them now.
    private func releaseHeldKittyKeys() {
        let flags = Int(snapshot?.kitty_flags ?? 0)
        if flags & KittyKeyEncoder.reportEvents != 0 {
            for var input in kittyDown.values {
                input.event = .release
                if case let .bytes(bytes) = KittyKeyEncoder.encode(input, flags: flags) { send(String(decoding: bytes, as: UTF8.self)) }
            }
            if flags & KittyKeyEncoder.reportAllKeys != 0 {
                for code in heldModifierKeys {
                    if case let .bytes(bytes) = KittyKeyEncoder.encodeModifier(keyCode: code, modifiers: [], pressed: false, flags: flags) { send(String(decoding: bytes, as: UTF8.self)) }
                }
            }
        }
        kittyDown.removeAll(); heldModifierKeys.removeAll()
    }
    public override func keyDown(with event: NSEvent) {
        switch kittyKey(event, type: event.isARepeat ? .repeat : .press) {
        case let .bytes(bytes):
            if let input = KittyKeyInput(event: event, optionAsAlt: preferences.optionAsAlt, type: .press) { kittyDown[event.keyCode] = input }
            send(String(decoding: bytes, as: UTF8.self)); return
        case .none: return
        case .legacy: break
        }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.control), let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            let value = scalar.value
            if value >= 64 && value <= 127 { send(String(UnicodeScalar(value & 0x1f)!)); return }
            if scalar == " " { send("\0"); return }
        }
        let app = snapshot?.app_cursor == true
        let arrows: [UInt16: String] = [123: "D", 124: "C", 125: "B", 126: "A"]
        if let code = arrows[event.keyCode], !hasMarkedText() {
            let modifiers = event.modifierFlags
            let mask = (modifiers.contains(.shift) ? 1 : 0) + (modifiers.contains(.option) ? 2 : 0) + (modifiers.contains(.control) ? 4 : 0)
            send(mask > 0 ? "\u{1b}[1;\(mask + 1)\(code)" : "\u{1b}\(app ? "O" : "[")\(code)"); return
        }
        let special: [UInt16: String] = [36: "\r", 76: "\r", 48: "\t", 51: "\u{7f}", 53: "\u{1b}", 117: "\u{1b}[3~", 115: "\u{1b}[H", 119: "\u{1b}[F", 116: "\u{1b}[5~", 121: "\u{1b}[6~", 122: "\u{1b}OP", 120: "\u{1b}OQ", 99: "\u{1b}OR", 118: "\u{1b}OS", 114: "\u{1b}[2~", 105: "\u{1b}[25~", 107: "\u{1b}[26~", 113: "\u{1b}[28~", 106: "\u{1b}[29~", 64: "\u{1b}[31~", 79: "\u{1b}[32~", 80: "\u{1b}[33~", 90: "\u{1b}[34~", 96: "\u{1b}[15~", 97: "\u{1b}[17~", 98: "\u{1b}[18~", 100: "\u{1b}[19~", 101: "\u{1b}[20~", 109: "\u{1b}[21~", 103: "\u{1b}[23~", 111: "\u{1b}[24~"]
        if !hasMarkedText(), let text = special[event.keyCode] {
            let sequence = event.keyCode == 48 && event.modifierFlags.contains(.shift) ? "\u{1b}[Z" : text
            send(preferences.optionAsAlt && event.modifierFlags.contains(.option) ? "\u{1b}" + sequence : sequence); return
        }
        if preferences.optionAsAlt, event.modifierFlags.contains(.option), !hasMarkedText(), let text = event.charactersIgnoringModifiers, !text.isEmpty {
            send("\u{1b}" + text); return
        }
        interpretKeyEvents([event])
    }
    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)): send("\r")
        case #selector(deleteBackward(_:)): send("\u{7f}")
        case #selector(insertTab(_:)): send("\t")
        case #selector(cancelOperation(_:)): composition.cancel(); send("\u{1b}")
        default: break
        }
    }
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        send(composition.commit(text)); redraw()
    }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        composition.mark((string as? NSAttributedString)?.string ?? (string as? String ?? "")); redraw()
    }
    public func unmarkText() { composition.cancel(); redraw() }
    public func hasMarkedText() -> Bool { !composition.text.isEmpty }
    public func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: composition.text.utf16.count) : NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange {
        guard let snapshot, let start = selectionStart, let end = selectionEnd else { return NSRange(location: NSNotFound, length: 0) }
        let a = snapshot.textOffset(row: start.0, col: start.1), b = snapshot.textOffset(row: end.0, col: end.1)
        let last = a <= b ? end : start
        let finish = snapshot.textOffset(row: last.0, col: last.1 + 1)
        return NSRange(location: min(a,b), length: max(0,finish - min(a,b)))
    }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let text = (snapshot?.text ?? "") as NSString
        guard range.location != NSNotFound, range.location <= text.length else { return nil }
        let safe = NSRange(location: range.location, length: min(range.length, text.length - range.location))
        actualRange?.pointee = safe; return NSAttributedString(string: text.substring(with: safe))
    }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.font, .foregroundColor, .underlineStyle] }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let rect = NSRect(x: 8 + CGFloat(snapshot?.cursor.col ?? 0)*cellSize.width, y: 8 + CGFloat(snapshot?.cursor.row ?? 0)*cellSize.height, width: cellSize.width, height: cellSize.height)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }
    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return 0 }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let cell = position(local)
        return snapshot?.textOffset(row: cell.0, col: cell.1) ?? 0
    }
    private func position(_ point: NSPoint) -> (Int, Int) {
        Self.cell(at: point, cellSize: cellSize, rows: snapshot?.rows ?? 1, cols: snapshot?.cols ?? 1)
    }
    /// The grid cell under a view point, clamped to the grid. Input methods hand `characterIndex(for:)` arbitrary
    /// screen points, so the clamp happens before the integer conversion, which would trap on a huge or non-finite value.
    nonisolated static func cell(at point: NSPoint, cellSize: CGSize, rows: Int, cols: Int) -> (Int, Int) {
        func index(_ offset: CGFloat, _ extent: CGFloat, _ count: Int) -> Int {
            let last = max(0, count - 1), value = offset / extent
            return value.isFinite ? Int(min(max(0, value), CGFloat(last))) : 0
        }
        return (index(point.y - 8, cellSize.height, rows), index(point.x - 8, cellSize.width, cols))
    }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.command), let snapshot {
            let cell = position(convert(event.locationInWindow, from: nil))
            if let url = snapshot.hyperlink(row: cell.0, col: cell.1) { NSWorkspace.shared.open(url); return }
        }
        if reportMouse(event, button: 0) { return }
        clearSelection()
        selectionStart = position(convert(event.locationInWindow, from: nil)); selectionEnd = nil
    }
    public override func mouseDragged(with event: NSEvent) {
        if snapshot?.mouse_mode == true && !event.modifierFlags.contains(.option) {
            if snapshot?.mouse_drag == true { _ = reportMouse(event, button: 32) }; return
        }
        if selectionStart == nil { selectionStart = position(convert(event.locationInWindow, from: nil)) }
        selectionEnd = position(convert(event.locationInWindow, from: nil)); updateSelection() }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    public override func mouseUp(with event: NSEvent) { _ = reportMouse(event, button: 0, release: true) }
    public override func rightMouseDown(with event: NSEvent) { _ = reportMouse(event, button: 2) }
    public override func rightMouseUp(with event: NSEvent) { _ = reportMouse(event, button: 2, release: true) }
    public override func otherMouseDown(with event: NSEvent) { _ = reportMouse(event, button: 1) }
    public override func otherMouseUp(with event: NSEvent) { _ = reportMouse(event, button: 1, release: true) }
    public override func mouseMoved(with event: NSEvent) {
        if snapshot?.mouse_motion == true { _ = reportMouse(event, button: 35) }
    }
    private func reportMouse(_ event: NSEvent, button: Int, release: Bool = false) -> Bool {
        guard !stopped else { return true }
        guard let snapshot, snapshot.mouse_mode, !event.modifierFlags.contains(.option) else { return false }
        let cell = position(convert(event.locationInWindow, from: nil))
        let modifiers = (event.modifierFlags.contains(.shift) ? 4 : 0) + (event.modifierFlags.contains(.control) ? 16 : 0)
        if let bytes = MouseEncoding.encode(button: button, row: cell.0, col: cell.1, release: release, sgr: snapshot.mouse_sgr, modifiers: modifiers) {
            do { _ = try session.call("input_bytes", ["bytes": bytes]) } catch { show(error) }
        }
        return true
    }
    public override func becomeFirstResponder() -> Bool {
        if snapshot?.focus_reporting == true { send("\u{1b}[I") }
        return true
    }
    public override func resignFirstResponder() -> Bool {
        releaseHeldKittyKeys()
        if snapshot?.focus_reporting == true { send("\u{1b}[O") }
        return true
    }
    /// Drops the host selection, its copy/accessibility text, and the cached highlight.
    /// Schema 1 has no deselect request, so the cached snapshot's marks are cleared too;
    /// otherwise a plain click would leave the previous highlight and Cmd-C its text.
    private func clearSelection() {
        let hadMarks = snapshot?.cells.contains(where: \.selected) == true
        let hadSelection = hadMarks || !selectedText.isEmpty || selectionStart != nil || selectionEnd != nil
        selectionStart = nil; selectionEnd = nil; selectedText = ""
        if hadMarks {
            snapshot?.clearSelectionMarks()
            pendingDamage = nil
            redraw()
        }
        if hadSelection { NSAccessibility.post(element: self, notification: .selectedTextChanged) }
    }
    private func updateSelection() {
        guard let start = selectionStart, let end = selectionEnd else { return }
        selectCells(from: start, to: end)
    }
    /// Applies a visible-cell selection and publishes its text. Internal so tests can
    /// exercise selection without synthesising drag events.
    func selectCells(from start: (Int, Int), to end: (Int, Int)) {
        guard !stopped else { return }
        do {
            let data = try session.call("select", ["start_row": start.0, "start_col": start.1, "end_row": end.0, "end_col": end.1])
            selectedText = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String ?? ""
            NSAccessibility.post(element: self, notification: .selectedTextChanged); poll()
        } catch { show(error) }
    }
    public override func scrollWheel(with event: NSEvent) {
        guard !stopped else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if reportMouse(event, button: delta > 0 ? 64 : 65) { return }
        if snapshot?.alternate == true && !event.modifierFlags.contains(.option) {
            let arrow = delta > 0 ? "A" : "B"
            send("\u{1b}\(snapshot?.app_cursor == true ? "O" : "[")\(arrow)"); return
        }
        do { _ = try session.call("scroll", ["lines": delta > 0 ? max(1,Int(delta)) : min(-1,Int(delta))]); poll() } catch { show(error) }
    }
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !stopped, snapshot?.control?.agent != true, sender.draggingSourceOperationMask.contains(.copy),
              (try? DropPolicy.text(from: sender.draggingPasteboard)) != nil else { return [] }
        return .copy
    }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptDrop(from: sender.draggingPasteboard)
    }
    @discardableResult func acceptDrop(from pasteboard: NSPasteboard) -> Bool {
        guard !stopped else { return false }
        do {
            guard try session.snapshot()?.control?.agent != true else { throw AkittyError.core("Reclaim terminal control before dropping files or text.") }
            guard let text = try DropPolicy.text(from: pasteboard) else { return false }
            window?.makeFirstResponder(self); paste(text); return true
        } catch { show(error); return false }
    }
    @objc public func copy(_ sender: Any?) {
        guard !selectedText.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedText, forType: .string)
    }
    @objc public func paste(_ sender: Any?) {
        guard !stopped else { return }
        guard let text = NSPasteboard.general.string(forType: .string), ClipboardPolicy.acceptsText(text) else { onStatus?("Paste requires plain text up to 64 KiB"); return }
        paste(text)
    }
    /// Sends already-validated clipboard text. Control or multiline text must not reach
    /// the PTY without confirmation; without a window there is nowhere to ask, so fail closed.
    func paste(_ text: String) {
        guard !stopped, ClipboardPolicy.acceptsText(text) else { return }
        if ClipboardPolicy.needsPasteConfirmation(text) {
            guard let window else { onStatus?("Paste requires confirmation, but the terminal is not in a window"); return }
            let alert = NSAlert(); alert.messageText = "Paste text containing control characters?"
            alert.informativeText = "This text may execute commands in the terminal."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Paste")
            alert.beginSheetModal(for: window) { [weak self] result in if result == .alertSecondButtonReturn { self?.send(text, paste: true) } }
        } else { send(text, paste: true) }
    }
    private func showClipboardRequest() {
        guard !stopped, !clipboardPromptOpen, !pendingClipboard.isEmpty, let window, window.attachedSheet == nil else { return }
        let text = pendingClipboard.removeFirst()
        guard ClipboardPolicy.acceptsText(text) else { showClipboardRequest(); return }
        clipboardPromptOpen = true
        let alert = NSAlert(); alert.messageText = "Allow this terminal to replace the clipboard?"
        alert.informativeText = "\(snapshot?.title ?? "Akitty") requests a plain-text clipboard write (\(text.utf8.count) bytes).\n\n\(String(text.prefix(300)))"
        alert.addButton(withTitle: "Deny"); alert.addButton(withTitle: "Allow Once")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn && !self.stopped {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
            self.clipboardPromptOpen = false; self.showClipboardRequest()
        }
    }
    public func changeFont(_ delta: CGFloat?) { fontSize = delta.map { min(36,max(9,fontSize + $0)) } ?? preferences.fontSize; resizeTerminal(); redraw() }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityLabel() -> String? { "Akitty terminal" }
    public override func accessibilityValue() -> Any? { snapshot?.text ?? "" }
    public override func accessibilitySelectedText() -> String? { selectedText }
    public override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }
    public override func accessibilityNumberOfCharacters() -> Int { snapshot?.text.utf16.count ?? 0 }
    public override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: accessibilityNumberOfCharacters()) }
    public override func accessibilityString(for range: NSRange) -> String? { attributedSubstring(forProposedRange: range, actualRange: nil)?.string }
    public override func accessibilityInsertionPointLineNumber() -> Int { snapshot?.cursor.row ?? 0 }
}

/// Forwards display-link ticks without keeping the view alive; a released view leaves the link to its `deinit`.
private final class DisplayLinkProxy: NSObject {
    private weak var view: TerminalView?
    init(_ view: TerminalView) { self.view = view }
    @MainActor @objc func tick(_ link: CADisplayLink) {
        if let view { view.displayTick(link) } else { link.invalidate() }
    }
}
