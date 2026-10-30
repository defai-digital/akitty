import AppKit

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
    init(headless: Bool = false, directory: String? = nil) throws {
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
/// One tab in the bar, laid out like a native macOS tab (Ghostty's): a close button on the left, the centred title,
/// and the ⌘-number that selects it on the right. The close button shows on the selected tab and on hover; clicking
/// anywhere else selects the tab, and dragging sideways reorders it.
@MainActor final class TabChip: NSView {
    let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!, target: nil, action: nil)
    private let title = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
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
        for view in [closeButton, title, shortcutLabel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16), closeButton.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4), title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        setAccessibilityLabel(label); setAccessibilityValue(isSelected)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || hovering else { return }
        (isSelected ? NSColor.quaternaryLabelColor : NSColor.quinaryLabelColor).setFill()
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
    let tabs = NSTabView()
    private let tabStrip = NSStackView()
    private(set) var tabChips: [TabChip] = []
    /// The tab being dragged. Chips are reused by position, so after a move the chip under the pointer shows a
    /// different tab; the drag follows the tab, not the chip.
    private weak var draggedTab: NSTabViewItem?
    private let headless: Bool
    /// Starting directory for every tab and split in this window; nil uses the Settings directory.
    let directory: String?
    /// Defaults to the system setting. Tests set this to force the sprite onto frame 0.
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { didSet { refreshChromeMark() } }
    private var chromeDocument: ChromeDocument?
    private var chromeMark: ChromeMarkAccessory?
    private var updateReminder: UpdateReminder?
    weak var app: AkittyApplication?
    private var palette: PaletteController?
    private let closeConfirmation = CloseConfirmation()
    let findBar = FindBar()
    private var findBarHeight: NSLayoutConstraint!
    private var findBarGap: NSLayoutConstraint!
    /// The query last sent to the core. Return advances when the field still holds it.
    private var searchedQuery: String?
    var panes: [TerminalPane] { tabs.tabViewItems.flatMap { ($0.view as? NSSplitView)?.arrangedSubviews.compactMap { $0 as? TerminalPane } ?? [] } }
    var active: TerminalView? { (window?.firstResponder as? TerminalView) ?? (tabs.selectedTabViewItem?.view as? NSSplitView)?.arrangedSubviews.compactMap { ($0 as? TerminalPane)?.terminal }.first }
    init(app: AkittyApplication, headless: Bool = false, directory: String? = nil) throws {
        self.headless = headless
        self.directory = directory
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1000,height: 650), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Akitty"; window.minSize = NSSize(width: 400,height: 250); window.center()
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
        let item = NSTabViewItem(identifier: UUID()); item.label = "Terminal"; item.view = split
        tabs.addTabViewItem(item); tabs.selectTabViewItem(item)
        do { try addPane(to: split) }
        catch { tabs.removeTabViewItem(item); refreshTabs(); throw error }
        refreshTabs()
    }
    private func addPane(to split: NSSplitView) throws {
        guard split.arrangedSubviews.count < 8 else { return }
        let pane = try TerminalPane(headless: headless, directory: directory); split.addArrangedSubview(pane)
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
        pane.terminal.onTitle = { [weak self, weak split] title in
            guard let self else { return }
            self.tabs.tabViewItems.first { $0.view === split }?.label = title
            self.refreshTabs()
            if self.tabs.selectedTabViewItem?.view === split { self.window?.title = title == "Akitty" ? title : "\(title) — Akitty" }
        }
        pane.terminal.onChrome = { [weak self, weak split] chrome in
            guard let self, self.tabs.selectedTabViewItem?.view === split else { return }
            self.chromeDocument = chrome
            self.refreshChromeMark()
        }
        window?.makeFirstResponder(pane.terminal)
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
            chip.label = item.label; chip.isSelected = item === tabs.selectedTabViewItem
            chip.shortcut = shortcut(forTab: index)
            chip.onSelect = { [weak self, weak item] in if let item { self?.draggedTab = item; self?.tabs.selectTabViewItem(item) } }
            chip.onDrag = { [weak self] x in
                guard let self, let dragged = self.draggedTab, let target = self.tabChips.firstIndex(where: { x < $0.frame.maxX }) ?? self.tabChips.indices.last else { return }
                self.moveTab(dragged, to: target)
            }
            chip.onClose = { [weak self, weak item] in if let item { self?.closeTab(item) } }
            chip.contextMenu = { [weak self, weak item] in self.flatMap { owner in item.map(owner.tabMenu) } ?? NSMenu() }
        }
    }
    /// Moves a tab to a new position, keeping it selected if it was.
    func moveTab(_ item: NSTabViewItem, to index: Int) {
        let from = tabs.indexOfTabViewItem(item)
        guard from != NSNotFound, from != index, tabs.tabViewItems.indices.contains(index) else { return }
        let selected = tabs.selectedTabViewItem === item
        tabs.removeTabViewItem(item); tabs.insertTabViewItem(item, at: index)
        if selected { tabs.selectTabViewItem(item) }
        refreshTabs()
    }
    /// ⌘1 to ⌘8 select that tab and ⌘9 the last one; an index past the last tab does nothing.
    func selectTab(at index: Int) {
        let target = index == 8 ? tabs.numberOfTabViewItems - 1 : index
        if tabs.tabViewItems.indices.contains(target) { tabs.selectTabViewItem(at: target) }
    }
    func refreshUpdateReminder(_ version: String?) {
        if let old = updateReminder, let index = window?.titlebarAccessoryViewControllers.firstIndex(of: old) { window?.removeTitlebarAccessoryViewController(at: index) }
        updateReminder = nil
        if let version, let updater = app?.updates { let reminder = UpdateReminder(version: version, updater: updater); window?.addTitlebarAccessoryViewController(reminder); updateReminder = reminder }
    }
    private func refreshChromeMark() {
        if let old = chromeMark, let index = window?.titlebarAccessoryViewControllers.firstIndex(of: old) {
            window?.removeTitlebarAccessoryViewController(at: index)
        }
        chromeMark = nil
        guard let pixels = chromeDocument?.shownPixels(reduceMotion: reduceMotion), let sprite = chromeDocument?.sprite else { return }
        let accessory = ChromeMarkAccessory(pixels: pixels, width: sprite.w, height: sprite.h)
        window?.addTitlebarAccessoryViewController(accessory)
        chromeMark = accessory
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        refreshTabs()
        if let pane = (tabViewItem?.view as? NSSplitView)?.arrangedSubviews.compactMap({ $0 as? TerminalPane }).first {
            window?.makeFirstResponder(pane.terminal)
            chromeDocument = pane.terminal.snapshot?.chrome
            refreshChromeMark()
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
            case .find: showFind()
            case .findNext: showFind(); runSearch(findBar.query == searchedQuery ? "next" : "latest")
            case .findPrevious: showFind(); runSearch("previous")
            case .fontIncrease: terminal?.changeFont(1)
            case .fontDecrease: terminal?.changeFont(-1)
            case .fontReset: terminal?.changeFont(nil)
            }
        } catch { NSAlert(error: error).runModal() }
    }
    func showPalette() {
        guard let window else { return }
        let target = active
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
        if split.arrangedSubviews.isEmpty, let item = tabs.tabViewItems.first(where: { $0.view === split }) { tabs.removeTabViewItem(item) }
        refreshTabs()
        if tabs.numberOfTabViewItems == 0 { window?.close() } else { window?.makeFirstResponder(active) }
    }
    private var editingFind: Bool { window?.firstResponder is NSTextView && findBar.window != nil && !findBar.isHidden }
    var findQuery: String { get { findBar.query } set { findBar.field.stringValue = newValue } }
    var findStatus: String { findBar.status.stringValue }
    var findBarVisible: Bool { !findBar.isHidden }
    func showFind() {
        let wasHidden = findBar.isHidden
        findBar.isHidden = false; findBarHeight.constant = 28; findBarGap.constant = 4
        window?.layoutIfNeeded()
        window?.makeFirstResponder(findBar.field)
        if wasHidden { findBar.field.currentEditor()?.selectAll(nil) }
    }
    func closeFind() {
        findBar.isHidden = true; findBarHeight.constant = 0; findBarGap.constant = 0; searchedQuery = nil
        if let terminal = active {
            _ = try? terminal.session.call("find", ["clear": true]); terminal.poll()
            window?.makeFirstResponder(terminal)
        }
    }
    /// `direction` is `latest`, `next`, or `previous`. An empty field clears the highlight.
    func runSearch(_ direction: String) {
        guard let terminal = active else { return }
        let text = findBar.query
        if text.isEmpty {
            _ = try? terminal.session.call("find", ["clear": true]); searchedQuery = nil; findBar.status.stringValue = ""; terminal.poll(); return
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
    private var windows: [TerminalWindow] = []
    let updates = UpdateController()
    private var settingsWindow: PreferencesWindow?
    private var launched = false
    private var openedFolderAtLaunch = false
    private enum TerminationState { case idle, confirming, closing }
    private var terminationState = TerminationState.idle
    private let quitConfirmation = CloseConfirmation()
    public func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        updates.onReminderChanged = { [weak self] version in self?.windows.forEach { $0.refreshUpdateReminder(version) } }
        makeMenu()
        // A cold launch for a folder delivers application(_:open:) before this; that window replaces the default one.
        if !openedFolderAtLaunch { newWindow(nil) }
        NSApp.activate(ignoringOtherApps: true); updates.start()
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
    func newWindow(directory: String?) {
        do { let controller = try TerminalWindow(app: self, directory: directory); windows.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        catch { NSAlert(error: error).runModal() }
    }
    fileprivate func remove(_ controller: TerminalWindow) { windows.removeAll { $0 === controller } }
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
        if command == .newWindow { newWindow(nil); return }
        guard let window = NSApp.keyWindow?.windowController as? TerminalWindow else {
            // Settings and palette text fields: keep normal editing for the shared Edit menu.
            switch command {
            case .copy: NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
            case .paste: NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
            default: break
            }
            return
        }
        window.perform(command)
    }
    @objc private func selectTab(_ sender: NSMenuItem) { (NSApp.keyWindow?.windowController as? TerminalWindow)?.selectTab(at: sender.tag) }
    @objc private func palette(_ sender: Any?) { (NSApp.keyWindow?.windowController as? TerminalWindow)?.showPalette() }
    @objc private func settings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = PreferencesWindow(updater: updates) }
        settingsWindow?.showWindow(nil); settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    private func makeMenu() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); let submenu = NSMenu(title: title); item.submenu = submenu; bar.addItem(item); return submenu }
        let app = menu("Akitty")
        app.addItem(withTitle: "About Akitty", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = app.addItem(withTitle: "Settings…", action: #selector(self.settings(_:)), keyEquivalent: ","); settings.target = self
        let update = app.addItem(withTitle: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: ""); update.target = updates
        app.addItem(.separator()); app.addItem(withTitle: "Quit Akitty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = menu("Shell"), edit = menu("Edit"), view = menu("View")
        func add(_ command: NativeCommand, key: String, modifiers: NSEvent.ModifierFlags = [.command], to menu: NSMenu) {
            let item = menu.addItem(withTitle: command.title, action: #selector(self.command(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = self; item.representedObject = command.rawValue
        }
        add(.newWindow,key: "n",to: file); add(.newTab,key: "t",to: file); add(.split,key: "d",to: file); add(.closePane,key: "w",to: file)
        add(.copy,key: "c",to: edit); add(.paste,key: "v",to: edit); add(.find,key: "f",to: edit)
        add(.findNext,key: "g",to: edit); add(.findPrevious,key: "g",modifiers: [.command, .shift],to: edit)
        let paletteItem = view.addItem(withTitle: "Command Palette…", action: #selector(palette(_:)), keyEquivalent: "p"); paletteItem.keyEquivalentModifierMask = [.command,.shift]; paletteItem.target = self
        add(.fontIncrease,key: "+",to: view); add(.fontDecrease,key: "-",to: view); add(.fontReset,key: "0",to: view)
        let window = menu("Window"); NSApp.windowsMenu = window
        window.addItem(withTitle: "Minimize",action: #selector(NSWindow.performMiniaturize(_:)),keyEquivalent: "m")
        window.addItem(withTitle: "Enter Full Screen",action: #selector(NSWindow.toggleFullScreen(_:)),keyEquivalent: "")
        window.addItem(.separator())
        for index in 0..<9 { let item = window.addItem(withTitle: index == 8 ? "Show Last Tab" : "Show Tab \(index + 1)", action: #selector(selectTab(_:)), keyEquivalent: "\(index + 1)"); item.tag = index; item.target = self }
    }
}
