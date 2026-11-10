import AppKit
import AppIntents

/// A close request must not enter a nested application-modal event loop or
/// enqueue more confirmations behind a sheet the user is already answering.
@MainActor final class CloseConfirmation {
    private var alert: NSAlert?
    @discardableResult func present(in window: NSWindow, title: String, message: String, action: String = "Close", completion: @escaping (Bool) -> Void) -> Bool {
        guard alert == nil, window.attachedSheet == nil else {
            window.attachedSheet?.makeKeyAndOrderFront(nil)
            return false
        }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[1].keyEquivalent = "\u{1b}"
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            alert.window.orderOut(nil)
            self?.alert = nil
            completion(response == .alertFirstButtonReturn)
        }
        return true
    }
    func cancel() {
        if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
    }
}

@MainActor final class TerminalPane: NSView {
    private var terminalStorage: TerminalView?
    var terminal: TerminalView { terminalStorage! }
    let status = NSTextField(labelWithString: "Starting shell…")
    /// Directory passed at creation. Nil means the Settings directory.
    let launchDirectory: String?
    init(headless: Bool = false, directory: String? = nil) throws {
        launchDirectory = directory
        super.init(frame: .zero)
        terminalStorage = try TerminalView(headless: headless, directory: directory)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        terminal.translatesAutoresizingMaskIntoConstraints = false; status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal); addSubview(status)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor), terminal.leadingAnchor.constraint(equalTo: leadingAnchor), terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -2),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4), status.heightAnchor.constraint(equalToConstant: 16)
        ])
        terminal.onStatus = { [weak status] message in status?.stringValue = message }
    }
    required init?(coder: NSCoder) { nil }
}
/// What a tab's programs report through program chrome, shown in its chip. Several tabs can run agents at once, so
/// the state belongs to each tab rather than to the window.
enum TabActivity: Equatable {
    case none
    /// Progress or the busy mark is current. Pixels are the shown sprite frame, when the program sent a sprite.
    case working(pixels: Data?, width: Int, height: Int)
    /// Work ended while the tab was not in view. Cleared when the tab is shown.
    case finished
    /// The bell rang while the tab was not in view. Cleared when the tab is shown.
    case bell
    case blocked, reportedError, reportedDone
    /// What assistive technology reads for the mark; nil when there is nothing to show.
    var accessibilityName: String? {
        switch self {
        case .none: return nil
        case .working: return "Working"
        case .finished: return "Finished"
        case .bell: return "Bell"
        case .blocked: return "Program reports waiting for you"
        case .reportedError: return "Program reports an error"
        case .reportedDone: return "Program reports completion; result not verified"
        }
    }
}

/// What a tab and the window show for a shell title. Like Ghostty, a bell that rang while the tab was out of view
/// prefixes the title with 🔔 until the tab is shown, so a window in the background says which tab wants attention.
enum TabTitle {
    /// The core's title before a program sets one and after it clears or resets it.
    static let defaultTitle = "Akitty"
    static func label(_ title: String, bell: Bool) -> String { bell ? "🔔 \(title)" : title }
    /// The window names its selected tab, then the app after an em dash unless the tab still has the default title.
    static func window(_ title: String, bell: Bool) -> String {
        let label = label(title, bell: bell)
        return title == defaultTitle ? label : "\(label) — Akitty"
    }
}

/// The chip's activity mark: the program's own sprite while it works, a dot once work it did out of view ends, and a
/// bell when it rang out of view. The bell lives here as well as in the title because the title truncates its head.
@MainActor final class TabActivityMark: NSView {
    var activity: TabActivity = .none {
        didSet {
            guard activity != oldValue else { return }
            image = Self.image(for: activity)
            isHidden = activity == .none
            setAccessibilityLabel(activity.accessibilityName)
            needsDisplay = true
        }
    }
    private var image: NSBitmapImageRep?
    /// Ghostty's bell glyph, in the warning colour so it reads apart from the working and finished dots.
    private static let bellImage = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.systemOrange])))
    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityIdentifier("tab-activity")
    }
    required init?(coder: NSCoder) { nil }
    /// Copies one straight-alpha RGBA8 frame into a bitmap; nil when the size does not match.
    static func bitmap(pixels: Data, width: Int, height: Int) -> NSBitmapImageRep? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: width * 4, bitsPerPixel: 32),
              let destination = rep.bitmapData else { return nil }
        pixels.withUnsafeBytes { raw in
            if let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) { destination.update(from: source, count: pixels.count) }
        }
        return rep
    }
    /// Whole-number enlargement keeps pixel art crisp; any other scale (a detailed sprite on a 1x display) is smoothed.
    nonisolated static func interpolation(edge: Int, devicePixels: CGFloat) -> NSImageInterpolation {
        let ratio = devicePixels / CGFloat(max(1, edge))
        return ratio >= 1 && ratio.rounded() == ratio ? .none : .high
    }
    private static func image(for activity: TabActivity) -> NSBitmapImageRep? {
        guard case let .working(pixels?, width, height) = activity else { return nil }
        return bitmap(pixels: pixels, width: width, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        switch activity {
        case .none: return
        case .finished:
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
        case .bell:
            guard let bell = Self.bellImage else { return }
            let size = bell.size
            bell.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .blocked, .reportedError, .reportedDone:
            let name = activity == .blocked ? "pause.circle.fill" : activity == .reportedError ? "exclamationmark.circle.fill" : "checkmark.circle"
            NSImage(systemSymbolName: name, accessibilityDescription: activity.accessibilityName)?.draw(in: bounds)
        case .working:
            guard let image else {
                // A program that reports work without a sprite gets a plain accent dot.
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
                return
            }
            let side = min(bounds.width, bounds.height)
            let edge = max(image.pixelsWide, image.pixelsHigh)
            let scale = side / CGFloat(edge)
            let size = NSSize(width: CGFloat(image.pixelsWide) * scale, height: CGFloat(image.pixelsHigh) * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            let interpolation = Self.interpolation(edge: edge, devicePixels: side * (window?.backingScaleFactor ?? 2))
            NSGraphicsContext.current?.imageInterpolation = interpolation
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: interpolation.rawValue)])
        }
    }
}

/// One tab in the bar, laid out like a native macOS tab (Ghostty's): a close button on the left, the centred title,
/// and the ⌘-number that selects it on the right. The close button shows on the selected tab and on hover; clicking
/// anywhere else selects the tab, and dragging sideways reorders it.
@MainActor final class TabChip: NSView {
    let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!, target: nil, action: nil)
    private let title = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    let activityMark = TabActivityMark()
    var activity: TabActivity { get { activityMark.activity } set { activityMark.activity = newValue; refresh() } }
    var shortcut: String { get { shortcutLabel.stringValue } set { shortcutLabel.stringValue = newValue } }
    var onSelect: (() -> Void)?, onClose: (() -> Void)?, contextMenu: (() -> NSMenu)?
    /// The pointer's x in the tab strip while this tab is dragged.
    var onDrag: ((CGFloat) -> Void)?
    private var dragStart: CGFloat?, dragging = false
    var label: String { get { title.stringValue } set { title.stringValue = newValue; closeButton.setAccessibilityLabel("Close \(newValue)") } }
    var isSelected = false { didSet { refresh() } }
    private var hovering = false { didSet { refresh() } }
    init() {
        super.init(frame: .zero)
        closeButton.isBordered = false; closeButton.imageScaling = .scaleProportionallyDown; closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close tab"; closeButton.setAccessibilityIdentifier("close-terminal-tab")
        closeButton.target = self; closeButton.action = #selector(closeClicked(_:))
        title.font = .systemFont(ofSize: 12); title.alignment = .center
        // Like Ghostty, keep the end of a long title: the deepest directory or the command's arguments.
        title.lineBreakMode = .byTruncatingHead
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutLabel.font = .systemFont(ofSize: 11); shortcutLabel.textColor = .tertiaryLabelColor; shortcutLabel.alignment = .right
        shortcutLabel.setAccessibilityElement(false)
        for view in [closeButton, title, activityMark, shortcutLabel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        // The mark sits just before the ⌘-number; the title keeps clear of it either way, so it does not jump.
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16), closeButton.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4), title.trailingAnchor.constraint(equalTo: activityMark.leadingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityMark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28), activityMark.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityMark.widthAnchor.constraint(equalToConstant: 14), activityMark.heightAnchor.constraint(equalToConstant: 14),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 20)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.radioButton)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    private func refresh() {
        closeButton.alphaValue = isSelected || hovering ? 1 : 0
        // A narrow tab gives its room to the title first.
        shortcutLabel.isHidden = bounds.width < 120
        title.textColor = isSelected ? .labelColor : .secondaryLabelColor
        let state = activity.accessibilityName.map { ", \($0.lowercased())" } ?? ""
        setAccessibilityLabel(label + state); setAccessibilityValue(isSelected)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || hovering else { return }
        (isSelected ? NSColor.quaternaryLabelColor : NSColor.quaternaryLabelColor.withAlphaComponent(0.06)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override func layout() { super.layout(); refresh() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { dragStart = event.locationInWindow.x; dragging = false; onSelect?() }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let strip = superview else { return }
        // A few points of slack so a slightly shaky click is still a click.
        if !dragging, abs(event.locationInWindow.x - start) < 4 { return }
        dragging = true
        onDrag?(strip.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil; dragging = false }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onClose?() } }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    @objc private func closeClicked(_ sender: Any?) { onClose?() }
}

/// A tab menu entry that remembers which tabs it acts on.
final class TabMenuItem: NSMenuItem { var tabs: [NSTabViewItem] = [] }

/// The find bar. Return moves to the next hit, Shift-Return to the previous, and Escape closes it.
@MainActor final class FindBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    let status = NSTextField(labelWithString: "")
    var onChange: (() -> Void)?, onSubmit: ((Bool) -> Void)?, onCancel: (() -> Void)?, onStep: ((Bool) -> Void)?
    var query: String { field.stringValue }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = "Find in scrollback"; field.delegate = self
        field.setAccessibilityLabel("Find in scrollback"); field.setAccessibilityIdentifier("find-query")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("find-status")
        let previous = button("chevron.left", "Find previous", identifier: "find-previous", action: #selector(stepBackward(_:)))
        let next = button("chevron.right", "Find next", identifier: "find-next", action: #selector(stepForward(_:)))
        let close = button("xmark", "Close find", identifier: "find-close", action: #selector(closeClicked(_:)))
        let stack = NSStackView(views: [field, previous, next, status, close])
        stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ obj: Notification) { onChange?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { onSubmit?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        return false
    }
    @objc private func stepBackward(_ sender: Any?) { onStep?(true) }
    @objc private func stepForward(_ sender: Any?) { onStep?(false) }
    @objc private func closeClicked(_ sender: Any?) { onCancel?() }
    private func button(_ symbol: String, _ label: String, identifier: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .smallSquare; button.imageScaling = .scaleProportionallyDown
        button.toolTip = label; button.setAccessibilityLabel(label); button.setAccessibilityIdentifier(identifier)
        return button
    }
}

@MainActor final class TerminalWindow: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    var quickDismiss: (() -> Void)?
    let tabs = NSTabView()
    private let tabStrip = NSStackView()
    private(set) var tabChips: [TabChip] = []
    /// The tab being dragged. Chips are reused by position, so after a move the chip under the pointer shows a
    /// different tab; the drag follows the tab, not the chip.
    private weak var draggedTab: NSTabViewItem?
    private let headless: Bool
    /// Folder this window was opened with. A new tab uses the focused pane's reported
    /// directory when that path still exists, and this folder otherwise. Splits use this
    /// folder. Nil uses the Settings directory.
    let directory: String?
    /// Defaults to the system setting. Tests set this to force the sprite onto frame 0.
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { didSet { refreshTabs() } }
    /// Tabs (by their split view) whose programs reported work at the last chrome update.
    private var workingTabs: Set<ObjectIdentifier> = []
    /// Tabs whose work ended while they were out of view; each keeps a dot until it is shown.
    private var finishedTabs: Set<ObjectIdentifier> = []
    /// Tabs whose bell rang while they were out of view; each keeps a bell mark and a 🔔 title until it is shown.
    private var belledTabs: Set<ObjectIdentifier> = []
    /// While a tab is detached to reorder it, NSTabView selects a neighbour; that is not the user looking at it.
    private var reorderingTabs = false
    private var updateReminder: UpdateReminder?
    weak var app: AkittyApplication?
    private var palette: PaletteController?
    private let closeConfirmation = CloseConfirmation()
    let findBar = FindBar()
    private var findBarHeight: NSLayoutConstraint!
    private var findBarGap: NSLayoutConstraint!
    /// The query last sent to the core. Return advances when the field still holds it.
    private var searchedQuery: String?
    /// The pane the find bar searches. The bar takes first responder, so `active` cannot
    /// answer once it is shown; remember the focused or palette-targeted pane instead.
    private weak var findTarget: TerminalView?
    var panes: [TerminalPane] { tabs.tabViewItems.flatMap { ($0.view as? NSSplitView)?.arrangedSubviews.compactMap { $0 as? TerminalPane } ?? [] } }
    var active: TerminalView? { (window?.firstResponder as? TerminalView) ?? (tabs.selectedTabViewItem?.view as? NSSplitView)?.arrangedSubviews.compactMap { ($0 as? TerminalPane)?.terminal }.first }
    /// The selected tab's first pane. `newTab()` selects its tab before returning,
    /// so a foreground action reads the pane it created even before focus settles.
    var selectedPane: TerminalView? { (tabs.selectedTabViewItem?.view as? NSSplitView)?.arrangedSubviews.compactMap { ($0 as? TerminalPane)?.terminal }.first }
    init(app: AkittyApplication, headless: Bool = false, directory: String? = nil) throws {
        self.headless = headless
        self.directory = directory
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1000,height: 650), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Akitty"; window.minSize = NSSize(width: 400,height: 250); window.center()
        // The controller owns the window and is itself released from windowWillClose; a window that also
        // releases itself on close risks an over-release, as every other window in the app already avoids.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self; tabs.delegate = self; tabs.tabViewType = .noTabsNoBorder
        let content = NSView()
        let bar = NSStackView(); bar.orientation = .horizontal; bar.spacing = 6; bar.distribution = .fill
        // Like native tabs, every tab gets an equal share of the bar and Auto Layout keeps it so as the window resizes.
        tabStrip.orientation = .horizontal; tabStrip.spacing = 2; tabStrip.distribution = .fillEqually
        tabStrip.setHuggingPriority(.defaultLow, for: .horizontal)
        tabStrip.setAccessibilityElement(true); tabStrip.setAccessibilityRole(.tabGroup); tabStrip.setAccessibilityLabel("Terminal tabs")
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New terminal tab")!, target: self, action: #selector(addTab(_:)))
        plus.bezelStyle = .circular; plus.contentTintColor = .labelColor; plus.toolTip = "New tab (⌘T)"; plus.setAccessibilityIdentifier("new-terminal-tab")
        plus.setContentHuggingPriority(.required, for: .horizontal)
        bar.addArrangedSubview(tabStrip); bar.addArrangedSubview(plus)
        findBar.isHidden = true
        findBar.onChange = { [weak self] in self?.runSearch("latest") }
        findBar.onSubmit = { [weak self] shift in
            guard let self else { return }
            let direction = if shift { "previous" } else if self.findBar.query == self.searchedQuery { "next" } else { "latest" }
            self.runSearch(direction)
        }
        findBar.onStep = { [weak self] previous in self?.runSearch(previous ? "previous" : "next") }
        findBar.onCancel = { [weak self] in self?.closeFind() }
        for view in [bar, findBar, tabs] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        // A hidden bar adds nothing between the tab strip and the terminals.
        findBarGap = tabs.topAnchor.constraint(equalTo: findBar.bottomAnchor)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 4), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8), bar.heightAnchor.constraint(equalToConstant: 28),
            plus.widthAnchor.constraint(equalToConstant: 30), tabStrip.heightAnchor.constraint(equalTo: bar.heightAnchor),
            findBar.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4), findBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8), findBarHeight, findBarGap,
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor), tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        try newTab(); refreshUpdateReminder(app.updates.availableVersion)
    }
    required init?(coder: NSCoder) { nil }
    func newTab() throws {
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let item = NSTabViewItem(identifier: UUID()); item.label = TabTitle.defaultTitle; item.view = split
        // Read the focused pane before the new tab becomes selected.
        let directory = directoryForNewTab()
        let selected = tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? NSNotFound
        let index = selected == NSNotFound ? tabs.numberOfTabViewItems : selected + 1
        if index >= tabs.numberOfTabViewItems { tabs.addTabViewItem(item) } else { tabs.insertTabViewItem(item, at: index) }
        tabs.selectTabViewItem(item)
        do { try addPane(to: split, directory: directory) }
        catch { tabs.removeTabViewItem(item); refreshTabs(); throw error }
        refreshTabs()
    }
    /// The focused pane's current directory, copied at the moment the tab is created.
    /// A missing or non-directory report falls back to the folder this window was opened with.
    private func directoryForNewTab() -> String? {
        guard let terminal = active else { return directory }
        let reported = (try? terminal.session.shellState())?.shell?.cwd
        if let reported, Self.existingDirectory(reported) { return reported }
        return directory
    }
    /// True when `path` is an absolute directory the new shell can start in.
    static func existingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    @discardableResult
    private func addPane(to split: NSSplitView, directory paneDirectory: String? = nil, at index: Int? = nil) throws -> TerminalPane? {
        // A restart replaces a pane, so it may briefly hold a ninth before the old one is removed.
        guard index != nil || split.arrangedSubviews.count < 8 else { return nil }
        let pane = try TerminalPane(headless: headless, directory: paneDirectory ?? directory)
        // A restart inserts in place; a new split appends as before.
        if let index { split.insertArrangedSubview(pane, at: min(max(index, 0), split.arrangedSubviews.count)) }
        else { split.addArrangedSubview(pane) }
        app?.registerAgentTerminal(pane.terminal)
        pane.terminal.onExit = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.close(pane.terminal)
        }
        DispatchQueue.main.async { [weak split] in
            guard let split else { return }
            split.adjustSubviews()
            let count = split.arrangedSubviews.count
            if count > 1 { for index in 1..<count { split.setPosition(split.bounds.width * CGFloat(index) / CGFloat(count), ofDividerAt: index - 1) } }
        }
        // The item keeps the raw title; the chip and the window add the bell prefix when they show it.
        pane.terminal.onTitle = { [weak self, weak split] title in
            guard let self else { return }
            self.tabs.tabViewItems.first { $0.view === split }?.label = title
            self.refreshTabs()
        }
        // A bell in view only beeps; out of view it marks the tab until the user looks, as Ghostty's bell title does.
        pane.terminal.onBell = { [weak self, weak split] in
            guard let self, let split, !self.inView(split) else { return }
            self.belledTabs.insert(ObjectIdentifier(split)); self.refreshTabs()
        }
        // Every tab reports, not only the selected one: background tabs are the ones whose state matters most.
        pane.terminal.onChrome = { [weak self, weak split] _ in
            guard let self, let split else { return }
            self.refreshActivity(of: split)
        }
        window?.makeFirstResponder(pane.terminal)
        return pane
    }
    /// Split the tab holding `terminal` (or the active pane) and return the new
    /// pane. Unlike the key command, a full tab reports why instead of doing nothing.
    func splitPane(containing terminal: TerminalView?) throws -> TerminalView {
        guard let target = terminal ?? active else { throw AkittyError.core("Open an AkiTTY terminal first.") }
        guard let item = tabs.tabViewItems.first(where: { (($0.view as? NSSplitView)?.arrangedSubviews ?? []).contains { ($0 as? TerminalPane)?.terminal === target } }),
              let split = item.view as? NSSplitView else {
            throw AkittyError.core("That terminal is no longer open. Choose a current AkiTTY terminal.")
        }
        // Check before selecting, so a refused split leaves the user's tab and focus alone.
        guard split.arrangedSubviews.count < 8 else { throw AkittyError.core("This tab already has 8 panes.") }
        tabs.selectTabViewItem(item)
        guard let pane = try addPane(to: split) else { throw AkittyError.core("This tab already has 8 panes.") }
        return pane.terminal
    }
    /// Restart the focused pane, keeping its tab and index.
    func restartFocusedPane() { if let terminal = active { restart(terminal) } }
    /// Replaces a pane with a fresh shell in the same slot, so an engine failure is recoverable.
    private func restart(_ terminal: TerminalView) {
        guard panes.contains(where: { $0.terminal === terminal }) else { return }
        // An exited pane (including an engine failure) has nothing left to stop, so restart at once.
        if terminal.snapshot?.exited == true { replace(terminal); return }
        guard let window else { return }
        closeConfirmation.present(in: window, title: "Restart this terminal?", message: "Running processes will be stopped.") { [weak self, weak terminal] approved in
            if approved, let terminal { self?.replace(terminal) }
        }
    }
    private func replace(_ terminal: TerminalView) {
        guard let pane = panes.first(where: { $0.terminal === terminal }), let split = pane.superview as? NSSplitView,
              let index = split.arrangedSubviews.firstIndex(of: pane) else { return }
        // A failed session may no longer report, so fall back to where this pane started.
        let reported = (try? terminal.session.shellState())?.shell?.cwd
        let directory = reported.flatMap { Self.existingDirectory($0) ? $0 : nil } ?? pane.launchDirectory ?? self.directory
        do {
            // Insert before removing: an empty split would close the tab (and window) in between.
            guard let replacement = try addPane(to: split, directory: directory, at: index) else { return }
            remove(terminal)
            window?.makeFirstResponder(replacement.terminal)
            refreshTabs()
        } catch { NSAlert(error: error).runModal() }
    }
    @objc private func addTab(_ sender: Any?) { do { try newTab() } catch { NSAlert(error: error).runModal() } }
    private func refreshTabs() {
        // Chips are reused, not rebuilt, so a title change under the pointer keeps the hover state.
        while tabChips.count > tabs.numberOfTabViewItems { tabChips.removeLast().removeFromSuperview() }
        while tabChips.count < tabs.numberOfTabViewItems {
            let chip = TabChip(); chip.translatesAutoresizingMaskIntoConstraints = false
            chip.heightAnchor.constraint(equalToConstant: 26).isActive = true
            // Soft, so many tabs truncate their titles instead of forcing the window wider.
            let minimum = chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 64); minimum.priority = .defaultHigh; minimum.isActive = true
            tabStrip.addArrangedSubview(chip); tabChips.append(chip)
        }
        for (index, (chip, item)) in zip(tabChips, tabs.tabViewItems).enumerated() {
            chip.label = TabTitle.label(item.label, bell: belled(item)); chip.isSelected = item === tabs.selectedTabViewItem; chip.activity = activity(of: item)
            chip.shortcut = shortcut(forTab: index)
            chip.onSelect = { [weak self, weak item] in if let item { self?.draggedTab = item; self?.tabs.selectTabViewItem(item) } }
            chip.onDrag = { [weak self] x in
                guard let self, let dragged = self.draggedTab, let target = self.tabChips.firstIndex(where: { x < $0.frame.maxX }) ?? self.tabChips.indices.last else { return }
                self.moveTab(dragged, to: target)
            }
            chip.onClose = { [weak self, weak item] in if let item { self?.closeTab(item) } }
            chip.contextMenu = { [weak self, weak item] in self.flatMap { owner in item.map(owner.tabMenu) } ?? NSMenu() }
        }
        refreshWindowTitle()
    }
    /// The window names the selected tab, so switching tabs or acknowledging its bell renames it at once.
    private func refreshWindowTitle() {
        guard let item = tabs.selectedTabViewItem else { return }
        window?.title = TabTitle.window(item.label, bell: belled(item))
    }
    private func belled(_ item: NSTabViewItem) -> Bool {
        (item.view as? NSSplitView).map { belledTabs.contains(ObjectIdentifier($0)) } ?? false
    }
    /// Moves a tab to a new position, keeping it selected if it was.
    func moveTab(_ item: NSTabViewItem, to index: Int) {
        let from = tabs.indexOfTabViewItem(item)
        guard from != NSNotFound, from != index, tabs.tabViewItems.indices.contains(index) else { return }
        let selected = tabs.selectedTabViewItem === item
        reorderingTabs = true
        tabs.removeTabViewItem(item); tabs.insertTabViewItem(item, at: index)
        reorderingTabs = false
        if selected {
            tabs.selectTabViewItem(item)
            if let pane = (item.view as? NSSplitView)?.arrangedSubviews.compactMap({ $0 as? TerminalPane }).first {
                window?.makeFirstResponder(pane.terminal)
            }
        }
        refreshTabs()
    }
    /// ⌘1 to ⌘8 select that tab and ⌘9 the last one; an index past the last tab does nothing.
    /// Selects the tab holding `terminal`, brings this window forward and focuses that pane.
    func focus(_ terminal: TerminalView) {
        guard let item = tabs.tabViewItems.first(where: { (($0.view as? NSSplitView)?.arrangedSubviews ?? []).contains { ($0 as? TerminalPane)?.terminal === terminal } }) else { return }
        tabs.selectTabViewItem(item)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(terminal)
    }
    func selectTab(at index: Int) {
        let target = index == 8 ? tabs.numberOfTabViewItems - 1 : index
        if tabs.tabViewItems.indices.contains(target) { tabs.selectTabViewItem(at: target) }
    }
    func refreshUpdateReminder(_ version: String?) {
        if let old = updateReminder, let index = window?.titlebarAccessoryViewControllers.firstIndex(of: old) { window?.removeTitlebarAccessoryViewController(at: index) }
        updateReminder = nil
        if let version, let updater = app?.updates { let reminder = UpdateReminder(version: version, updater: updater); window?.addTitlebarAccessoryViewController(reminder); updateReminder = reminder }
    }
    /// The first pane in the split whose program reports work, if any.
    private func workingChrome(in split: NSSplitView) -> ChromeDocument? {
        split.arrangedSubviews.lazy.compactMap { ($0 as? TerminalPane)?.terminal.snapshot }.first { !$0.exited && $0.chrome?.isWorking == true }?.chrome
    }
    /// Whether the user can see this tab now: it is selected in the key window.
    private func inView(_ split: NSSplitView) -> Bool { tabs.selectedTabViewItem?.view === split && window?.isKeyWindow == true }
    private func refreshActivity(of split: NSSplitView) {
        let id = ObjectIdentifier(split)
        if workingChrome(in: split) != nil { workingTabs.insert(id); finishedTabs.remove(id) }
        else if workingTabs.remove(id) != nil, !inView(split) { finishedTabs.insert(id) }
        refreshTabs()
    }
    private func activity(of item: NSTabViewItem) -> TabActivity {
        guard let split = item.view as? NSSplitView else { return .none }
        // A bell asks for the user, so it outranks the sprite until the tab is shown.
        if belledTabs.contains(ObjectIdentifier(split)) { return .bell }
        let reports = split.arrangedSubviews.compactMap { ($0 as? TerminalPane)?.terminal.snapshot?.program_status?.active }
        if reports.contains(where: { $0.state == "blocked" }) { return .blocked }
        if reports.contains(where: { $0.state == "error" }) { return .reportedError }
        if reports.contains(where: { $0.state == "working" }) {
            // Take the chrome of the same first pane whose report is working, not the first pane's.
            let chrome = split.arrangedSubviews.compactMap { ($0 as? TerminalPane)?.terminal.snapshot }
                .first { $0.program_status?.active?.state == "working" }?.chrome
            return .working(pixels: chrome?.shownPixels(reduceMotion: reduceMotion), width: chrome?.sprite?.w ?? 0, height: chrome?.sprite?.h ?? 0)
        }
        if reports.contains(where: { $0.state == "done" }) { return .reportedDone }
        if let chrome = workingChrome(in: split) {
            guard let sprite = chrome.sprite else { return .working(pixels: nil, width: 0, height: 0) }
            return .working(pixels: chrome.shownPixels(reduceMotion: reduceMotion), width: sprite.w, height: sprite.h)
        }
        return finishedTabs.contains(ObjectIdentifier(split)) ? .finished : .none
    }
    /// Showing a tab acknowledges work that finished, and a bell that rang, out of view.
    private func acknowledgeSelectedTab() {
        guard let split = tabs.selectedTabViewItem?.view as? NSSplitView else { return }
        let id = ObjectIdentifier(split)
        let finished = finishedTabs.remove(id) != nil, belled = belledTabs.remove(id) != nil
        if finished || belled { refreshTabs() }
    }
    func windowDidBecomeKey(_ notification: Notification) { acknowledgeSelectedTab() }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard !reorderingTabs else { return }
        if window?.isKeyWindow == true, let split = tabViewItem?.view as? NSSplitView {
            finishedTabs.remove(ObjectIdentifier(split)); belledTabs.remove(ObjectIdentifier(split))
        }
        refreshTabs()
        if let pane = (tabViewItem?.view as? NSSplitView)?.arrangedSubviews.compactMap({ $0 as? TerminalPane }).first {
            window?.makeFirstResponder(pane.terminal)
        }
    }
    func perform(_ command: NativeCommand, target: TerminalView? = nil) {
        let terminal = target ?? active
        do {
            switch command {
            case .newWindow: app?.newWindow(nil)
            case .newTab: try newTab()
            case .split: if let split = tabs.selectedTabViewItem?.view as? NSSplitView { try addPane(to: split) }
            case .closePane: if let terminal { close(terminal) }
            case .copy: if self.editingFind { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) } else { terminal?.copy(nil) }
            case .paste: if self.editingFind { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) } else { terminal?.paste(nil) }
            case .find: showFind(target)
            case .findNext: showFind(target); runSearch(findBar.query == searchedQuery ? "next" : "latest")
            case .findPrevious: showFind(target); runSearch("previous")
            case .fontIncrease: terminal?.changeFont(1)
            case .fontDecrease: terminal?.changeFont(-1)
            case .fontReset: terminal?.changeFont(nil)
            case .agentOverview: app?.showAgentOverview(nil)
            }
        } catch { NSAlert(error: error).runModal() }
    }
    func showPalette() {
        guard let window else { return }
        let target = editingFind ? findTarget ?? active : active
        palette = PaletteController { [weak self, weak target] command in self?.perform(command, target: target) }
        if let panel = palette?.window { window.beginSheet(panel) }
    }
    private func close(_ terminal: TerminalView) {
        guard panes.contains(where: { $0.terminal === terminal }) else { return }
        if terminal.snapshot?.exited == true { remove(terminal); return }
        guard let window else { return }
        closeConfirmation.present(in: window, title: "Close this terminal?", message: "Running processes will be stopped.") { [weak self, weak terminal] approved in
            if approved, let terminal { self?.remove(terminal) }
        }
    }
    func closeTab(_ item: NSTabViewItem) { closeTabs([item], title: "Close Tab?") }
    /// Closes every pane in the given tabs, after one confirmation if any of them is still running (as Ghostty does).
    func closeTabs(_ items: [NSTabViewItem], title: String) {
        let terminals = items.flatMap { (($0.view as? NSSplitView)?.arrangedSubviews ?? []).compactMap { ($0 as? TerminalPane)?.terminal } }
        if terminals.allSatisfy({ $0.snapshot?.exited == true }) { terminals.forEach(remove); return }
        guard let window else { return }
        let message = items.count == 1 ? "The terminal still has a running process. If you close the tab the process will be stopped." : "A terminal still has a running process. If you close these tabs the processes will be stopped."
        closeConfirmation.present(in: window, title: title, message: message) { [weak self] approved in
            if approved { terminals.forEach { self?.remove($0) } }
        }
    }
    /// The tab's right-click menu, with Ghostty's (and Safari's) close actions.
    func tabMenu(for item: NSTabViewItem) -> NSMenu {
        let menu = NSMenu(), index = tabs.indexOfTabViewItem(item), all = tabs.tabViewItems
        func add(_ title: String, _ items: [NSTabViewItem]) {
            let entry = TabMenuItem(title: title, action: #selector(closeTabsFromMenu(_:)), keyEquivalent: ""); entry.target = self
            entry.tabs = items; entry.isEnabled = !items.isEmpty; entry.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.autoenablesItems = false
        add("Close Tab", [item])
        add("Close Other Tabs", all.filter { $0 !== item })
        add("Close Tabs to the Right", index == NSNotFound ? [] : Array(all.dropFirst(index + 1)))
        return menu
    }
    @objc private func closeTabsFromMenu(_ sender: TabMenuItem) {
        let items = sender.tabs.filter { tabs.indexOfTabViewItem($0) != NSNotFound }
        if !items.isEmpty { closeTabs(items, title: items.count == 1 ? "Close Tab?" : "\(sender.title)?") }
    }
    /// ⌘1 to ⌘8 name the first eight tabs and ⌘9 the last, as in Ghostty, Safari and Terminal.
    private func shortcut(forTab index: Int) -> String {
        index == tabs.numberOfTabViewItems - 1 && index >= 8 ? "⌘9" : index < 8 ? "⌘\(index + 1)" : ""
    }
    private func remove(_ terminal: TerminalView) {
        guard let pane = panes.first(where: { $0.terminal === terminal }), let split = pane.superview as? NSSplitView else { return }
        terminal.shutdown(); split.removeArrangedSubview(pane); pane.removeFromSuperview()
        if split.arrangedSubviews.isEmpty, let item = tabs.tabViewItems.first(where: { $0.view === split }) {
            tabs.removeTabViewItem(item)
            workingTabs.remove(ObjectIdentifier(split)); finishedTabs.remove(ObjectIdentifier(split)); belledTabs.remove(ObjectIdentifier(split))
        } else {
            refreshActivity(of: split)
        }
        refreshTabs()
        if tabs.numberOfTabViewItems == 0 { window?.close() } else { window?.makeFirstResponder(active) }
    }
    private var editingFind: Bool { window?.firstResponder is NSTextView && findBar.window != nil && !findBar.isHidden }
    var findQuery: String { get { findBar.query } set { findBar.field.stringValue = newValue } }
    var findStatus: String { findBar.status.stringValue }
    var findBarVisible: Bool { !findBar.isHidden }
    /// The field owns focus while editing; otherwise the focused pane wins. A retained
    /// search owner is valid only in the selected tab, including after its old pane exits.
    private var searchOwner: TerminalView? {
        let visible = (tabs.selectedTabViewItem?.view as? NSSplitView)?.arrangedSubviews.compactMap { ($0 as? TerminalPane)?.terminal } ?? []
        if let focused = window?.firstResponder as? TerminalView, visible.contains(where: { $0 === focused }) { return focused }
        if let findTarget, visible.contains(where: { $0 === findTarget }) { return findTarget }
        return visible.first
    }
    private func setFindTarget(_ target: TerminalView?) {
        if findTarget !== target { clearFindHighlights(); findBar.status.stringValue = "" }
        findTarget = target
    }
    func showFind(_ target: TerminalView? = nil) {
        let wasHidden = findBar.isHidden
        let explicit = target.flatMap { candidate in panes.contains(where: { $0.terminal === candidate }) ? candidate : nil }
        setFindTarget(explicit ?? searchOwner)
        findBar.isHidden = false; findBarHeight.constant = 28; findBarGap.constant = 4
        window?.layoutIfNeeded()
        window?.makeFirstResponder(findBar.field)
        if wasHidden { findBar.field.currentEditor()?.selectAll(nil) }
    }
    func closeFind() {
        let owner = searchOwner
        findBar.isHidden = true; findBarHeight.constant = 0; findBarGap.constant = 0
        clearFindHighlights()
        findTarget = nil
        if let owner { window?.makeFirstResponder(owner) }
    }
    /// The bar is one per window, and a search can have highlighted any pane, so clear them all.
    private func clearFindHighlights() {
        searchedQuery = nil
        for pane in panes {
            _ = try? pane.terminal.session.call("find", ["clear": true])
            pane.terminal.poll()
        }
    }
    /// `direction` is `latest`, `next`, or `previous`. An empty field clears the highlight.
    func runSearch(_ direction: String) {
        guard let terminal = searchOwner else { return }
        setFindTarget(terminal)
        let text = findBar.query
        if text.isEmpty {
            clearFindHighlights(); findBar.status.stringValue = ""; return
        }
        let direction = direction == "previous" || text == searchedQuery ? direction : "latest"
        do {
            let data = try terminal.session.call("find", ["text": text, "direction": direction])
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let found = object?["found"] as? Bool ?? false
            findBar.status.stringValue = found ? ((object?["wrapped"] as? Bool == true) ? "Wrapped" : "") : "Not found"
            searchedQuery = text
            terminal.poll()
        } catch { findBar.status.stringValue = error.localizedDescription }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let quickDismiss { quickDismiss(); return false }
        if panes.isEmpty || panes.allSatisfy({ $0.terminal.snapshot?.exited == true }) { return true }
        closeConfirmation.present(in: sender, title: "Close this window?", message: "All terminal processes in this window will be stopped.") { [weak sender] approved in
            if approved { sender?.close() }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { closeConfirmation.cancel(); for pane in panes { pane.terminal.shutdown() }; app?.remove(self) }
}

@MainActor final class PaletteController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let features = FeatureHost()
    private let search = NSSearchField()
    private let table = NSTableView()
    private let warning = NSTextField(labelWithString: "")
    private var entries: [CommandDescriptor] = []
    private let execute: (NativeCommand) -> Void
    init(execute: @escaping (NativeCommand) -> Void) {
        self.execute = execute
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 520,height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Command Palette"
        super.init(window: panel)
        let content = NSView(); panel.contentView = content
        search.sendsWholeSearchString = true; search.sendsSearchStringImmediately = false
        search.placeholderString = "Search commands…"; search.delegate = self; search.target = self; search.action = #selector(runSelected)
        search.setAccessibilityLabel("Search commands")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")); column.width = 480; table.addTableColumn(column)
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.target = self; table.doubleAction = #selector(runSelected)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        warning.font = .systemFont(ofSize: 11); warning.textColor = .secondaryLabelColor
        for view in [search, scroll, warning] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor,constant: 16), search.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 16),search.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor,constant: 12),scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),scroll.bottomAnchor.constraint(equalTo: warning.topAnchor,constant: -8),
            warning.leadingAnchor.constraint(equalTo: search.leadingAnchor),warning.trailingAnchor.constraint(equalTo: search.trailingAnchor),warning.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -12),warning.heightAnchor.constraint(equalToConstant: 18)
        ])
        refresh(); panel.initialFirstResponder = search
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    private func refresh() { entries = features.search(search.stringValue); warning.stringValue = features.warning ?? "TypeScript command ranking · native Mac actions"; table.reloadData(); if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) } }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "\(entries[row].title)     \(entries[row].shortcut)"); label.font = .systemFont(ofSize: 14); return label
    }
    @objc private func runSelected() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let id = entries[table.selectedRow].id
        dismiss(); execute(id)
    }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    private func dismiss() { if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) } }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(moveDown(_:)) || selector == #selector(moveUp(_:)) {
            let delta = selector == #selector(moveDown(_:)) ? 1 : -1
            if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: (max(0,table.selectedRow)+delta+entries.count)%entries.count), byExtendingSelection: false) }; return true
        }
        if selector == #selector(cancelOperation(_:)) { dismiss(); return true }
        return false
    }
}

/// Folders requested by an open-documents event: Finder "Open With", a Dock drop, or `open -a Akitty <path>` (how
/// AX Code Desktop hands a project over). A file opens in its folder, as in Terminal. Missing paths, non-file URLs and
/// anything past `limit` are counted as skipped rather than dropped silently, and the limit keeps one event from
/// starting an unbounded number of shells.
struct FolderOpenRequest: Equatable {
    var directories: [String] = []
    var skipped = 0
}
func folderOpenRequest(from urls: [URL], limit: Int = 8) -> FolderOpenRequest {
    var request = FolderOpenRequest()
    for url in urls {
        var isDirectory: ObjCBool = false
        let path = url.standardizedFileURL.path
        guard url.isFileURL, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { request.skipped += 1; continue }
        let directory = isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
        if request.directories.contains(directory) { continue }
        guard request.directories.count < limit else { request.skipped += 1; continue }
        request.directories.append(directory)
    }
    return request
}

@MainActor public final class AkittyApplication: NSObject, NSApplicationDelegate {
    private(set) var windows: [TerminalWindow] = []
    let intentInstance = UUID().uuidString
    private var eventMenuItem: NSMenuItem?
    private lazy var agentRequests: AgentRequests = {
        let requests = AgentRequests(source: { [weak self] in self?.windows.flatMap(\.panes).map(\.terminal) ?? [] })
        requests.onFailure = { [weak self] message in self?.eventMenuItem?.title = "Agent Event Timeline (recording warning)…"; self?.eventMenuItem?.toolTip = message }
        return requests
    }()
    func registerAgentTerminal(_ terminal: TerminalView) {
        agentRequests.register(terminal)
        terminal.appEntityIdentifier = EntityIdentifier(for: TerminalEntity.self, identifier: intentID(for: terminal))
    }
    @objc private func toggleAgentRequests(_ sender: NSMenuItem) {
        do { try agentRequests.setEnabled(!agentRequests.enabled); sender.state = agentRequests.enabled ? .on : .off }
        catch { NSAlert(error: error).runModal() }
    }
    @objc private func showAgentTimeline(_ sender: Any?) { agentRequests.showTimeline() }
    @objc private func exportAgentEvents(_ sender: Any?) { agentRequests.exportEvents() }
    private lazy var quickTerminal: QuickTerminalController = {
        let controller = QuickTerminalController { [unowned self] in
            let window = try TerminalWindow(app: self); windows.append(window); return window
        }
        controller.onError = { NSAlert(error: $0).runModal() }
        return controller
    }()
    func configureQuickTerminal(_ preferences: TerminalPreferences) throws { try quickTerminal.configure(preferences) }
    @objc private func toggleQuickTerminal(_ sender: Any?) {
        do { try quickTerminal.toggle() } catch { NSAlert(error: error).runModal() }
    }
    func showQuickTerminal() throws {
        try quickTerminal.show()
        if !launched { openedFolderAtLaunch = true }
    }
    func revealQuickTerminalIfNeeded(_ window: TerminalWindow) throws {
        if window === quickTerminal.terminalWindow { try showQuickTerminal() }
    }
    /// The window a foreground action without a pane reference should use. The
    /// key window wins; otherwise a regular window. A hidden quick terminal is
    /// never chosen, so New Tab creates a window instead of revealing it.
    func intentWindow() -> TerminalWindow? {
        let regular = windows.filter { $0 !== quickTerminal.terminalWindow }
        return regular.first { $0.window?.isKeyWindow == true }
            ?? windows.first { $0.window?.isKeyWindow == true }
            ?? regular.first { $0.window?.isMainWindow == true }
            ?? regular.first ?? windows.first { $0.window?.isVisible == true }
    }
    func requestSiriCommand(_ command: String, in terminal: TerminalView) async throws {
        _ = try await agentRequests.request(command, in: terminal, origin: .siri)
    }
    public func applicationWillTerminate(_ notification: Notification) { agentRequests.stop(); quickTerminal.stop() }
    let updates = UpdateController()
    private var settingsWindow: PreferencesWindow?
    private(set) var agentOverview: AgentOverviewController?
    @objc func showAgentOverview(_ sender: Any?) {
        if agentOverview == nil {
            agentOverview = AgentOverviewController(source: { [weak self] in self?.windows ?? [] }, requestsEnabled: { [weak self] in self?.agentRequests.enabled == true }) { [weak self] window, terminal in
                // A hidden quick terminal is shown through its controller so its hide and focus restore keep working.
                if window === self?.quickTerminal.terminalWindow, window.window?.isVisible != true {
                    do { try self?.quickTerminal.toggle() } catch { NSAlert(error: error).runModal() }
                }
                window.focus(terminal)
            }
        }
        agentOverview?.showWindow(nil); agentOverview?.window?.makeKeyAndOrderFront(nil)
    }
    private var launched = false
    private var openedFolderAtLaunch = false
    private enum TerminationState { case idle, confirming, closing }
    private var terminationState = TerminationState.idle
    private let quitConfirmation = CloseConfirmation()
    public func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        agentRequests.startRecording()
        updates.onReminderChanged = { [weak self] version in self?.windows.forEach { $0.refreshUpdateReminder(version) } }
        makeMenu()
        do { try configureQuickTerminal(.load()) } catch { NSAlert(error: error).runModal() }
        // Intent/service launches must not create an extra shell. A folder or
        // intent delivered before didFinishLaunching also replaces the default.
        let defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        do { try createInitialWindowIfNeeded(defaultLaunch: defaultLaunch) } catch { NSAlert(error: error).runModal() }
        // A read-only intent can cold-launch without windows; activating would
        // pull AkiTTY forward for a background request. Foreground intents
        // activate themselves through showIntentWindow.
        if Self.shouldActivateAfterLaunch(windowCount: windows.count) { NSApp.activate(ignoringOtherApps: true) }
        updates.start()
    }
    /// A default launch or a folder opened before launch owns a window and still
    /// activates. A background intent launch has no window and stays in place.
    nonisolated static func shouldActivateAfterLaunch(windowCount: Int) -> Bool { windowCount > 0 }
    /// AppKit asks for an untitled window when a Dock, Finder or `open` launch ends with none. A launch that
    /// restores saved state (after a crash, a forced quit, or with "Close windows when quitting" off) is not
    /// default, so didFinishLaunching skips its window; AkiTTY restores none, so it opens one here. A
    /// background intent launch is not an open-application launch and never reaches this.
    public func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool { openUntitledWindow() }
    /// Only an app with no windows gets one, so a Dock reopen that already opened a window adds none.
    func openUntitledWindow(headless: Bool = false) -> Bool {
        guard windows.isEmpty else { return false }
        do { try createTerminalWindow(headless: headless) } catch { NSAlert(error: error).runModal(); return false }
        return true
    }
    public func application(_ sender: NSApplication, open urls: [URL]) {
        let request = folderOpenRequest(from: urls)
        for directory in request.directories { newWindow(directory: directory) }
        if !launched, !windows.isEmpty { openedFolderAtLaunch = true }
        if request.skipped > 0 {
            let alert = NSAlert(); alert.messageText = request.skipped == 1 ? "One item was not opened." : "\(request.skipped) items were not opened."
            alert.informativeText = "Akitty opens existing folders, at most 8 at a time."; alert.runModal()
        }
        if launched { NSApp.activate(ignoringOtherApps: true) }
    }
    @objc public func newWindow(_ sender: Any?) { newWindow(directory: nil) }
    func createInitialWindowIfNeeded(defaultLaunch: Bool, headless: Bool = false) throws {
        if !openedFolderAtLaunch && defaultLaunch { try createTerminalWindow(headless: headless) }
    }
    func newWindow(directory: String?) {
        do { _ = try createTerminalWindow(directory: directory) }
        catch { NSAlert(error: error).runModal() }
    }
    @discardableResult func createTerminalWindow(directory: String? = nil, headless: Bool = false) throws -> TerminalWindow {
        let controller = try TerminalWindow(app: self, headless: headless, directory: directory)
        windows.append(controller)
        if !launched { openedFolderAtLaunch = true }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }
    fileprivate func remove(_ controller: TerminalWindow) { quickTerminal.closed(controller); windows.removeAll { $0 === controller } }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let owner = windows.first(where: { $0.window?.isKeyWindow == true })?.window ?? windows.first?.window
        return requestTermination(terminals: windows.flatMap(\.panes).map(\.terminal), window: owner) { sender.reply(toApplicationShouldTerminate: $0) }
    }
    func requestTermination(terminals: [TerminalView], window: NSWindow?, reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard terminationState == .idle else { return .terminateLater }
        guard !terminals.isEmpty else { return .terminateNow }
        let shutdown = { [self] in
            terminationState = .closing
            let group = DispatchGroup()
            for terminal in terminals { group.enter(); terminal.shutdown { group.leave() } }
            group.notify(queue: .main) { reply(true) }
        }
        if terminals.contains(where: { $0.snapshot?.exited != true }) {
            guard let window else { return .terminateCancel }
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
            terminationState = .confirming
            let presented = quitConfirmation.present(in: window, title: "Quit Akitty?", message: "All running terminal processes will be stopped.", action: "Quit") { [self] approved in
                if approved { shutdown() }
                else { terminationState = .idle; reply(false) }
            }
            if !presented { terminationState = .idle; return .terminateCancel }
        } else {
            shutdown()
        }
        return .terminateLater
    }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { newWindow(nil) }; return true }
    @objc private func command(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let command = NativeCommand(rawValue: id) else { return }
        perform(command, in: NSApp.keyWindow, sender: sender)
    }
    func perform(_ command: NativeCommand, in keyWindow: NSWindow?, sender: NSMenuItem) {
        if command == .newWindow { newWindow(nil); return }
        // The overview is app-wide and opens from any key window, including itself.
        if command == .agentOverview { showAgentOverview(nil); return }
        guard let window = keyWindow?.windowController as? TerminalWindow else {
            // Utility windows keep native close and editing behavior; terminal panes retain their confirmation path.
            switch command {
            case .closePane: keyWindow?.performClose(sender)
            case .copy: NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
            case .paste: NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
            default: break
            }
            return
        }
        window.perform(command)
    }
    @objc private func selectTab(_ sender: NSMenuItem) { (NSApp.keyWindow?.windowController as? TerminalWindow)?.selectTab(at: sender.tag) }
    @objc private func restartTerminal(_ sender: Any?) { (NSApp.keyWindow?.windowController as? TerminalWindow)?.restartFocusedPane() }
    @objc private func palette(_ sender: Any?) { (NSApp.keyWindow?.windowController as? TerminalWindow)?.showPalette() }
    @objc private func settings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = PreferencesWindow(updater: updates) }
        settingsWindow?.showWindow(nil); settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func makeMenu() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); let submenu = NSMenu(title: title); item.submenu = submenu; bar.addItem(item); return submenu }
        let app = menu("Akitty")
        app.addItem(withTitle: "About Akitty", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = app.addItem(withTitle: "Settings…", action: #selector(self.settings(_:)), keyEquivalent: ","); settings.target = self
        let update = app.addItem(withTitle: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: ""); update.target = updates
        let requests = app.addItem(withTitle: "Enable Local Agent Requests", action: #selector(toggleAgentRequests(_:)), keyEquivalent: ""); requests.target = self
        let timeline = app.addItem(withTitle: "Agent Event Timeline…", action: #selector(showAgentTimeline(_:)), keyEquivalent: ""); timeline.target = self
        eventMenuItem = timeline
        let export = app.addItem(withTitle: "Export Agent Events…", action: #selector(exportAgentEvents(_:)), keyEquivalent: ""); export.target = self
        app.addItem(.separator()); app.addItem(withTitle: "Quit Akitty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = menu("Shell"), edit = menu("Edit"), view = menu("View")
        func add(_ command: NativeCommand, key: String, modifiers: NSEvent.ModifierFlags = [.command], to menu: NSMenu) {
            let item = menu.addItem(withTitle: command.title, action: #selector(self.command(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = self; item.representedObject = command.rawValue
        }
        let quick = file.addItem(withTitle: "Toggle Quick Terminal", action: #selector(toggleQuickTerminal(_:)), keyEquivalent: ""); quick.target = self
        add(.newWindow,key: "n",to: file); add(.newTab,key: "t",to: file); add(.split,key: "d",to: file); add(.closePane,key: "w",to: file)
        let restart = file.addItem(withTitle: "Restart Terminal", action: #selector(restartTerminal(_:)), keyEquivalent: "r")
        restart.keyEquivalentModifierMask = [.command, .shift]; restart.target = self
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        // Standard editing actions follow the focused responder, including terminal panes, fields and sheets.
        // Routing these through the app's key-window command handler can lose a paste during focus changes.
        edit.addItem(withTitle: NativeCommand.copy.title, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: NativeCommand.paste.title, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let reclaim = edit.addItem(withTitle: "Reclaim Terminal Control", action: #selector(TerminalView.reclaimAgentControl(_:)), keyEquivalent: "")
        reclaim.target = nil
        edit.addItem(.separator()); add(.find,key: "f",to: edit)
        add(.findNext,key: "g",to: edit); add(.findPrevious,key: "g",modifiers: [.command, .shift],to: edit)
        let paletteItem = view.addItem(withTitle: "Command Palette…", action: #selector(palette(_:)), keyEquivalent: "p"); paletteItem.keyEquivalentModifierMask = [.command,.shift]; paletteItem.target = self
        add(.fontIncrease,key: "+",to: view); add(.fontDecrease,key: "-",to: view); add(.fontReset,key: "0",to: view)
        let window = menu("Window"); NSApp.windowsMenu = window
        window.addItem(withTitle: "Minimize",action: #selector(NSWindow.performMiniaturize(_:)),keyEquivalent: "m")
        window.addItem(withTitle: "Enter Full Screen",action: #selector(NSWindow.toggleFullScreen(_:)),keyEquivalent: "")
        add(.agentOverview, key: "a", modifiers: [.command, .option], to: window)
        window.addItem(.separator())
        for index in 0..<9 { let item = window.addItem(withTitle: index == 8 ? "Show Last Tab" : "Show Tab \(index + 1)", action: #selector(selectTab(_:)), keyEquivalent: "\(index + 1)"); item.tag = index; item.target = self }
    }
}
