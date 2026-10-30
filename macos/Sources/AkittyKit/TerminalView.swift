import AppKit
import MetalKit
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
    private var presenter: MetalPresenter?
    private var bitmap: CGContext?
    private let snapshotQueue = DispatchQueue(label: "com.defai.akitty.snapshot", qos: .userInteractive)
    private let rasterQueue = DispatchQueue(label: "com.defai.akitty.raster", qos: .userInteractive)
    /// Keeps the bitmap between frames; only touched on `rasterQueue`.
    private let rasterizer = GridRasterizer()
    /// Grid rows changed since the last raster started; nil means unknown (repaint everything).
    private var pendingDamage: Set<Int>? = nil
    private var pollInFlight = false
    private var rasterInFlight = false
    private var rasterPending = false
    private let imageStore = ImageStore()
    private var lastCellPixels: (Int, Int) = (0, 0)
    private var timer: Timer?
    private var composition = Composition()
    private var tracking: NSTrackingArea?
    private var selectionStart: (Int, Int)?
    private var selectionEnd: (Int, Int)?
    private var selectedText = ""
    private var pendingClipboard: [String] = []
    private var clipboardPromptOpen = false
    private var lastGrid: (Int, Int) = (0, 0)
    /// Key codes whose press went out as a Kitty escape, so only those get a release.
    private var kittyDown: [UInt16: KittyKeyInput] = [:]
    /// Physical modifier keys currently down; a flags change alone cannot say which one moved.
    private var heldModifierKeys: Set<UInt16> = []
    private var stopped = false
    private var fontSize: CGFloat = 14
    private var preferences = TerminalPreferences.load()
    private var font: NSFont {
        if preferences.fontName != "System Monospaced", let selected = NSFont(name: preferences.fontName, size: fontSize) { return selected }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    public var cellSize: CGSize {
        CGSize(width: ceil(("M" as NSString).size(withAttributes: [.font: font]).width), height: ceil(font.ascender - font.descender + font.leading + 4))
    }
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
        sessionStorage = try TerminalSession(headless: headless, shell: initial.shell, directory: initial.directory, scrollback: initial.scrollback)
        preferences = initial; fontSize = initial.fontSize
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .terminalPreferencesChanged, object: nil)
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
        setAccessibilityIdentifier("akitty-terminal")
    }
    required init?(coder: NSCoder) { nil }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    @objc private func preferencesChanged() {
        preferences = TerminalPreferences.load(); fontSize = preferences.fontSize
        resizeTerminal(); redraw()
    }
    public func shutdown(completion: @escaping @Sendable () -> Void = {}) {
        guard !stopped else { completion(); return }; stopped = true
        timer?.invalidate(); timer = nil
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completion() }
            do { try session.close() } catch { Logger(subsystem: "com.defai.akitty", category: "pty").error("PTY close failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
    public override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resizeTerminal(); poll(); showClipboardRequest() }
    public override func layout() { super.layout(); presenter?.view.frame = bounds; resizeTerminal(); redraw() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); redraw() }
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
            }
        }
    }
    private func applySnapshot(_ result: Result<Snapshot?, Error>) {
        do {
            if let next = try result.get() {
                snapshot = next
                if next.exited, next.error == nil, next.exit_code == 0, !exitHandled {
                    exitHandled = true
                    DispatchQueue.main.async { [weak self] in self?.onExit?() }
                }
                if let error = next.error { onStatus?(error) }
                else if let failure = health.failure { onStatus?("Software rendering: \(failure)") }
                else if next.exited { onStatus?("Shell exited (\(next.exit_code.map(String.init) ?? "closed"))") }
                else { onStatus?("\(next.cols) cols × \(next.rows) rows") }
                onTitle?(next.title)
                // Clipboard replacement is latest-request-wins while another
                // prompt is open, keeping the approval queue bounded.
                if let text = next.clipboard.last { pendingClipboard = [text] }
                if next.partial == true, let dirty = next.dirty { pendingDamage?.formUnion(dirty) } else { pendingDamage = nil }
                redraw()
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
    private func redraw() {
        guard let snapshot, bounds.width > 0, bounds.height > 0, !stopped else { return }
        if rasterInFlight { rasterPending = true; return }
        rasterInFlight = true; rasterPending = false
        let size = bounds.size, scale = window?.backingScaleFactor ?? 2
        let fontName = font.fontName, fontSize = self.fontSize, cells = cellSize, marked = composition.text, images = imageStore.images
        // Reuse the bitmap only when the GPU path copies it out before the next frame starts drawing into it.
        let damage = pendingDamage, rasterizer = self.rasterizer, reuse = presenter != nil
        pendingDamage = []
        rasterQueue.async { [weak self] in
            let result = Result { try rasterizer.render(snapshot: snapshot, damage: damage, size: size, scale: scale, fontName: fontName, fontSize: fontSize, cellSize: cells, composition: marked, images: images, reuse: reuse) }
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
        NSColor(calibratedRed: 18/255, green: 22/255, blue: 29/255, alpha: 1).setFill(); bounds.fill()
        if let image = bitmap?.makeImage(), let context = NSGraphicsContext.current?.cgContext {
            context.saveGState(); context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: bounds); context.restoreGState()
        }
    }
    private func show(_ error: Error) { onStatus?(error.localizedDescription); NSSound.beep() }
    public func send(_ text: String, paste: Bool = false) {
        do { try session.input(text, paste: paste) } catch { show(error) }
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
        (min(max(0, Int((point.y-8)/cellSize.height)), max(0,(snapshot?.rows ?? 1)-1)),
         min(max(0, Int((point.x-8)/cellSize.width)), max(0,(snapshot?.cols ?? 1)-1)))
    }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.command), let snapshot {
            let cell = position(convert(event.locationInWindow, from: nil))
            if let url = snapshot.hyperlink(row: cell.0, col: cell.1) { NSWorkspace.shared.open(url); return }
        }
        if reportMouse(event, button: 0) { return }
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
    private func updateSelection() {
        guard let start = selectionStart, let end = selectionEnd else { return }
        do {
            let data = try session.call("select", ["start_row": start.0, "start_col": start.1, "end_row": end.0, "end_col": end.1])
            selectedText = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String ?? ""
            NSAccessibility.post(element: self, notification: .selectedTextChanged); poll()
        } catch { show(error) }
    }
    public override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if reportMouse(event, button: delta > 0 ? 64 : 65) { return }
        if snapshot?.alternate == true && !event.modifierFlags.contains(.option) {
            let arrow = delta > 0 ? "A" : "B"
            send("\u{1b}\(snapshot?.app_cursor == true ? "O" : "[")\(arrow)"); return
        }
        do { _ = try session.call("scroll", ["lines": delta > 0 ? max(1,Int(delta)) : min(-1,Int(delta))]); poll() } catch { show(error) }
    }
    @objc public func copy(_ sender: Any?) {
        guard !selectedText.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedText, forType: .string)
    }
    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), ClipboardPolicy.acceptsText(text) else { onStatus?("Paste requires plain text up to 64 KiB"); return }
        if ClipboardPolicy.needsPasteConfirmation(text), let window {
            let alert = NSAlert(); alert.messageText = "Paste text containing control characters?"
            alert.informativeText = "This text may execute commands in the terminal."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Paste")
            alert.beginSheetModal(for: window) { [weak self] result in if result == .alertSecondButtonReturn { self?.send(text, paste: true) } }
        } else { send(text, paste: true) }
    }
    private func showClipboardRequest() {
        guard !clipboardPromptOpen, !pendingClipboard.isEmpty, let window else { return }
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
