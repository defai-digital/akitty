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
    /// Directory passed at creation. Nil means the Settings directory.
    let launchDirectory: String?
    init(headless: Bool = false, directory: String? = nil, profile: UUID? = nil, restoredText: String? = nil) throws {
        launchDirectory = directory
        super.init(frame: .zero)
        terminalStorage = try TerminalView(headless: headless, directory: directory, profile: profile, restoredText: restoredText)
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
@MainActor final class TerminalWindow: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    var quickDismiss: (() -> Void)?
    let tabs = NSTabView()
    private let tabStrip = NSStackView()
    private(set) var tabChips: [TabChip] = []
    /// The tab being dragged. Chips are reused by position, so after a move the chip under the pointer shows a
    /// different tab; the drag follows the tab, not the chip.
    private weak var draggedTab: NSTabViewItem?
    private var dragOriginalIndex = 0
    private weak var dragOriginalSelection: NSTabViewItem?
    private var dragPreview: TabDragPreview?
    let headless: Bool
    private var closing = false
    /// Folder this window was opened with. The first tab and splits use this folder.
    /// Later tabs follow the focused pane's reported directory or its starting folder.
    /// Nil uses the Settings directory.
    let directory: String?
    /// Profile of the window's first pane. New tabs and splits take the focused pane's profile instead, so a
    /// window opened with a profile keeps it as it grows.
    let profile: UUID?
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
    init(app: AkittyApplication, headless: Bool = false, directory: String? = nil, profile: UUID? = nil, restoredText: String? = nil, createInitialTab: Bool = true) throws {
        self.headless = headless
        self.directory = directory
        self.profile = profile
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1000,height: 650), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Akitty"; window.minSize = NSSize(width: 400,height: 250); window.center()
        // The controller owns the window and is itself released from windowWillClose; a window that also
        // releases itself on close risks an over-release, as every other window in the app already avoids.
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
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
        if createInitialTab { try newTab(profile: profile, restoredText: restoredText) }
        refreshUpdateReminder(app.updates.availableVersion)
    }
    required init?(coder: NSCoder) { nil }
    func newTab() throws { try newTab(profile: inheritedProfile, copyDirectory: true) }
    /// The focused pane's profile, even when that is the defaults (nil); the window's own profile only without a pane.
    private var inheritedProfile: UUID? { if let active { return active.profileID }; return profile }
    /// Opens a tab whose first pane uses `profile` (nil: the Settings defaults). A tab chosen from New Tab with Profile
    /// passes `copyDirectory: false`, so it starts in the profile's (or Settings') folder rather than the focused pane's.
    /// A restored layout passes its saved folder as `directory`; nil there falls back to this window's folder.
    func newTab(profile: UUID?, copyDirectory: Bool = true, directory savedDirectory: String?? = nil, restoredText: String? = nil) throws {
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let item = NSTabViewItem(identifier: UUID()); item.label = TabTitle.defaultTitle; item.view = split
        // Read the focused pane before the new tab becomes selected.
        let directory = savedDirectory ?? (copyDirectory ? directoryForNewTab() : nil)
        // Ordinary tabs already resolved their source pane's folder; a missing one uses the profile defaults.
        let useWindowDirectory = savedDirectory != nil
        let selected = tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? NSNotFound
        let index = selected == NSNotFound ? tabs.numberOfTabViewItems : selected + 1
        if index >= tabs.numberOfTabViewItems { tabs.addTabViewItem(item) } else { tabs.insertTabViewItem(item, at: index) }
        tabs.selectTabViewItem(item)
        do { try addPane(to: split, directory: directory, profile: profile, useWindowDirectory: useWindowDirectory, restoredText: restoredText) }
        catch { tabs.removeTabViewItem(item); refreshTabs(); throw error }
        refreshTabs()
    }
    /// Records this window's tabs, panes, split shares and starting folders for a named layout. The shell's
    /// reported directory wins while it still exists; otherwise the folder the pane started with is kept.
    func captureLayout() -> WindowLayout.Window {
        let selected = tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? 0
        let captured = tabs.tabViewItems.map { item -> WindowLayout.Tab in
            let panes = (item.view as? NSSplitView)?.arrangedSubviews.compactMap { $0 as? TerminalPane } ?? []
            return WindowLayout.Tab(panes: panes.map { pane in
                let reported = (try? pane.terminal.session.shellState())?.shell?.cwd
                let directory = reported.flatMap { Self.existingDirectory($0) ? $0 : nil } ?? pane.terminal.startingDirectory
                return WindowLayout.Pane(directory: directory, profile: pane.terminal.profileID)
            }, fractions: fractions(of: panes))
        }
        let frame = window?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 650)
        return WindowLayout.Window(frame: [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)], selectedTab: selected, tabs: captured)
    }
    func captureLayout(includeScrollback: Bool) throws -> WindowLayout.Window {
        var value = captureLayout()
        guard includeScrollback else { return value }
        for (tab, item) in tabs.tabViewItems.enumerated() {
            let panes = (item.view as? NSSplitView)?.arrangedSubviews.compactMap { $0 as? TerminalPane } ?? []
            for (pane, source) in panes.enumerated() {
                let text = try source.terminal.session.recentText()
                value.tabs[tab].panes[pane].scrollback = text.isEmpty ? nil : text
            }
        }
        return value
    }
    /// Each pane's width over the split's total. Before AppKit lays out a headless window every width is zero,
    /// so equal shares keep a captured layout usable.
    private func fractions(of panes: [TerminalPane]) -> [Double] {
        guard !panes.isEmpty else { return [] }
        let widths = panes.map { max(0, Double($0.frame.width)) }
        let total = widths.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1 / Double(panes.count), count: panes.count) }
        return widths.map { $0 / total }
    }
    /// Builds a new window from a saved layout. The window opens in the first pane's folder (or the Settings
    /// folder), then every other pane and tab starts in its own saved folder. Processes are intentionally new.
    static func restored(app: AkittyApplication, headless: Bool = false, layout: WindowLayout.Window) throws -> TerminalWindow {
        let layoutTabs = layout.tabs.isEmpty ? [WindowLayout.Tab()] : layout.tabs
        let first = layoutTabs.first?.panes.first
        let controller = try TerminalWindow(app: app, headless: headless, directory: first.flatMap { restoringDirectory($0.directory) }, profile: first?.profile, restoredText: first?.scrollback)
        if let firstTab = layoutTabs.first, let split = controller.tabs.tabViewItems.first?.view as? NSSplitView {
            for pane in firstTab.panes.dropFirst() { try controller.addPane(to: split, directory: restoringDirectory(pane.directory), profile: .some(pane.profile), restoredText: pane.scrollback) }
        }
        for tab in layoutTabs.dropFirst() {
            let lead = tab.panes.first
            try controller.newTab(profile: lead?.profile, copyDirectory: false, directory: .some(lead.flatMap { restoringDirectory($0.directory) }), restoredText: lead?.scrollback)
            if let split = controller.tabs.selectedTabViewItem?.view as? NSSplitView {
                for pane in tab.panes.dropFirst() { try controller.addPane(to: split, directory: restoringDirectory(pane.directory), profile: .some(pane.profile), restoredText: pane.scrollback) }
            }
        }
        // Saved indices are literal; selectTab(at:) reserves 8 for the Command-9 last-tab shortcut.
        controller.tabs.selectTabViewItem(at: min(max(0, layout.selectedTab), controller.tabs.numberOfTabViewItems - 1))
        controller.window?.setFrame(WindowLayoutGeometry.restoredFrame(layout.frame), display: false)
        // addPane queues its own equal-width layout, so saved shares must be applied after those blocks run.
        DispatchQueue.main.async { [weak controller] in controller?.applyFractions(layoutTabs) }
        return controller
    }
    /// A saved folder is reused only while it is still an existing absolute directory; otherwise the window default applies.
    private static func restoringDirectory(_ path: String) -> String? {
        existingDirectory(path) ? path : nil
    }
    private func applyFractions(_ layoutTabs: [WindowLayout.Tab]) {
        window?.layoutIfNeeded()
        for (item, tab) in zip(tabs.tabViewItems, layoutTabs) {
            guard let split = item.view as? NSSplitView else { continue }
            let count = split.arrangedSubviews.count
            guard count > 1 else { continue }
            setShares(tab.fractions.count == count ? tab.fractions : Array(repeating: 1, count: count), of: split)
        }
    }
    /// Places each divider at the running total of `shares`, normalized so they need not sum to one.
    private func setShares(_ shares: [Double], of split: NSSplitView) {
        let total = shares.reduce(0, +)
        guard shares.count == split.arrangedSubviews.count, shares.count > 1, total > 0 else { return }
        var position = 0.0
        for divider in 0..<(shares.count - 1) {
            position += shares[divider] / total
            split.setPosition(split.bounds.width * CGFloat(position), ofDividerAt: divider)
        }
    }
    /// The focused pane's current directory, copied at the moment the tab is created.
    /// A missing or non-directory report falls back to where that pane started, including profile tabs.
    private func directoryForNewTab() -> String? {
        guard let terminal = active else { return directory }
        let reported = (try? terminal.session.shellState())?.shell?.cwd
        if let reported, Self.existingDirectory(reported) { return reported }
        return Self.existingDirectory(terminal.startingDirectory) ? terminal.startingDirectory : nil
    }
    /// True when `path` is an absolute directory the new shell can start in.
    static func existingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    @discardableResult
    private func addPane(to split: NSSplitView, directory paneDirectory: String? = nil, at index: Int? = nil, profile paneProfile: UUID?? = nil, useWindowDirectory: Bool = true, restoredText: String? = nil) throws -> TerminalPane? {
        // A restart replaces a pane, so it may briefly hold a ninth before the old one is removed.
        guard index != nil || split.arrangedSubviews.count < 8 else { return nil }
        // A split takes the profile of the pane it splits from; an explicit profile (even nil, the defaults) wins.
        let inheritedDirectory = useWindowDirectory ? directory.flatMap { Self.existingDirectory($0) ? $0 : nil } : nil
        let pane = try TerminalPane(headless: headless, directory: paneDirectory ?? inheritedDirectory, profile: paneProfile ?? inheritedProfile, restoredText: restoredText)
        // A restart inserts in place; a new split appends as before.
        if let index { split.insertArrangedSubview(pane, at: min(max(index, 0), split.arrangedSubviews.count)) }
        else { split.addArrangedSubview(pane) }
        app?.registerAgentTerminal(pane.terminal)
        bindPane(pane, in: split)
        DispatchQueue.main.async { [weak self, weak split] in
            guard let split else { return }
            split.adjustSubviews()
            self?.setShares(Array(repeating: 1, count: split.arrangedSubviews.count), of: split)
        }
        window?.makeFirstResponder(pane.terminal)
        return pane
    }
    /// Window callbacks follow the pane when its tab moves; session registration stays unchanged.
    private func bindPane(_ pane: TerminalPane, in split: NSSplitView) {
        pane.terminal.onExit = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.close(pane.terminal)
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
        guard let pane = try addPane(to: split, profile: .some(target.profileID)) else { throw AkittyError.core("This tab already has 8 panes.") }
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
        let directory = reported.flatMap { Self.existingDirectory($0) ? $0 : nil }
            ?? (Self.existingDirectory(terminal.startingDirectory) ? terminal.startingDirectory : nil)
        do {
            // Insert before removing: an empty split would close the tab (and window) in between.
            guard let replacement = try addPane(to: split, directory: directory, at: index, profile: .some(terminal.profileID), useWindowDirectory: false) else { return }
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
            chip.onSelect = { [weak self, weak item] in
                guard let self, let item else { return }
                self.draggedTab = item; self.dragOriginalIndex = self.tabs.indexOfTabViewItem(item)
                self.dragOriginalSelection = self.tabs.selectedTabViewItem
                self.tabs.selectTabViewItem(item)
            }
            chip.onDrag = { [weak self] point in self?.dragTab(to: point) }
            chip.onDrop = { [weak self] point in self?.dropTab(at: point) }
            chip.onCancelDrag = { [weak self] in self?.cancelTabDrag() }
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
    var allowsTabTransfer: Bool {
        !closing && quickDismiss == nil && window != nil && window?.attachedSheet == nil && NSApp.modalWindow == nil && app?.allowsTabTransfer == true
    }
    /// Reordering inside this window needs no application coordinator, so the quick terminal can reorder too.
    private var allowsTabReorder: Bool {
        !closing && window?.attachedSheet == nil && NSApp.modalWindow == nil && app?.allowsTabTransfer != false
    }
    func canTransferTab(_ item: NSTabViewItem) -> Bool {
        allowsTabTransfer && tabs.indexOfTabViewItem(item) != NSNotFound && (item.view as? NSSplitView)?.arrangedSubviews.isEmpty == false
    }
    /// The strip has vertical slack for slightly diagonal reordering, but accepts drops only over its width.
    func tabInsertionIndex(at point: NSPoint) -> Int? {
        guard allowsTabTransfer, let window else { return nil }
        let local = tabStrip.convert(window.convertPoint(fromScreen: point), from: nil)
        guard tabStrip.bounds.insetBy(dx: -12, dy: -16).contains(local) else { return nil }
        return tabChips.firstIndex { local.x < $0.frame.midX } ?? tabs.numberOfTabViewItems
    }
    /// The strip's height plus slack, but only across this window: at strip height over another window
    /// or the desktop the drag detaches instead of reordering.
    private func isInReorderBand(_ point: NSPoint) -> Bool {
        guard let window, point.x >= window.frame.minX, point.x <= window.frame.maxX else { return false }
        let local = tabStrip.convert(window.convertPoint(fromScreen: point), from: nil)
        return local.y >= tabStrip.bounds.minY - 24 && local.y <= tabStrip.bounds.maxY + 24
    }
    /// The topmost window at `point` across every app on the active Space. Nil when another app's
    /// window, or nothing of ours, is there, so a covered or off-Space window never takes the drop.
    /// The window server's topmost window number at a screen point. Tests replace it, since other apps'
    /// windows on the test machine would otherwise decide where a synthetic drop lands.
    static var windowNumberAtPoint: (NSPoint) -> Int = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
    private func frontmostAppWindow(at point: NSPoint) -> NSWindow? {
        let number = Self.windowNumberAtPoint(point)
        guard let hit = NSApp.windows.first(where: { $0.windowNumber == number }), hit.isOnActiveSpace,
              hit.isVisible, !hit.isMiniaturized, !hit.ignoresMouseEvents else { return nil }
        return hit
    }
    private func detachTab(_ item: NSTabViewItem, at point: NSPoint? = nil) -> Bool {
        guard let app else { return false }
        do { return try app.moveTabToNewWindow(item, from: self, at: point) != nil }
        catch { NSAlert(error: error).runModal(); return false }
    }
    private func dragTab(to point: NSPoint) {
        guard allowsTabReorder, let item = draggedTab else { return }
        if isInReorderBand(point) {
            dragPreview?.orderOut(nil)
            guard let window else { return }
            let x = tabStrip.convert(window.convertPoint(fromScreen: point), from: nil).x
            if let index = tabChips.firstIndex(where: { x < $0.frame.maxX }) ?? tabChips.indices.last { moveTab(item, to: index) }
        } else if canTransferTab(item) {
            if dragPreview == nil { dragPreview = TabDragPreview(title: item.label) }
            dragPreview?.follow(point)
        }
    }
    private func dropTab(at point: NSPoint) {
        let item = draggedTab, originalSelection = dragOriginalSelection, originalIndex = dragOriginalIndex
        dragPreview?.orderOut(nil); dragPreview = nil; draggedTab = nil; dragOriginalSelection = nil
        guard let item else { return }
        var accepted = false
        defer { if !accepted { restoreTabDrag(item, index: originalIndex, selection: originalSelection) } }
        guard canTransferTab(item), let app else { accepted = allowsTabReorder && isInReorderBand(point); return }
        // Hit the frontmost window, so a sheet, settings window or another app never drops through to a terminal behind it.
        guard let hit = frontmostAppWindow(at: point) else {
            accepted = detachTab(item, at: point); return
        }
        guard let destination = hit.windowController as? TerminalWindow, destination.app === app else { return }
        if destination === self {
            // A window's only tab dropped on its own content stays put: detaching would just replace the window.
            accepted = isInReorderBand(point) || (tabs.numberOfTabViewItems > 1 && detachTab(item, at: point))
        } else if let index = destination.tabInsertionIndex(at: point), transferTab(item, to: destination, at: index) {
            accepted = true
            destination.showWindow(nil); destination.window?.makeKeyAndOrderFront(nil)
        }
    }
    private func cancelTabDrag() {
        let item = draggedTab, selection = dragOriginalSelection, index = dragOriginalIndex
        dragPreview?.orderOut(nil); dragPreview = nil
        draggedTab = nil; dragOriginalSelection = nil
        if let item { restoreTabDrag(item, index: index, selection: selection) }
    }
    private func restoreTabDrag(_ item: NSTabViewItem, index: Int, selection: NSTabViewItem?) {
        guard !closing else { return }
        if tabs.indexOfTabViewItem(item) != NSNotFound { moveTab(item, to: max(0, min(index, tabs.numberOfTabViewItems - 1))) }
        if let selection, tabs.indexOfTabViewItem(selection) != NSNotFound { tabs.selectTabViewItem(selection) }
    }
    /// Moves the retained split tree atomically on the main actor. No PTY is opened, closed or registered again.
    @discardableResult func transferTab(_ item: NSTabViewItem, to destination: TerminalWindow, at index: Int) -> Bool {
        guard destination !== self, canTransferTab(item), destination.allowsTabTransfer,
              let app, destination.app === app, (0...destination.tabs.numberOfTabViewItems).contains(index),
              let split = item.view as? NSSplitView else { return false }
        let moved = split.arrangedSubviews.compactMap { $0 as? TerminalPane }
        guard !moved.isEmpty, moved.allSatisfy({ !$0.terminal.isShutdown }) else { return false }
        let shares = fractions(of: moved), key = ObjectIdentifier(split)
        // The Find target is the pane the user was searching, even when the field editor holds focus
        // or the tab is in the background, so it wins over the first responder.
        let searched = findTarget.flatMap { target in moved.contains { $0.terminal === target } ? target : nil }
        let focused = searched ?? moved.first { $0.terminal === window?.firstResponder }?.terminal ?? moved.first?.terminal
        let movingSelected = tabs.selectedTabViewItem === item, keepFindFocus = editingFind && !movingSelected
        if searched != nil { releaseFind(of: moved.map(\.terminal), hideBar: movingSelected) }
        reorderingTabs = true; destination.reorderingTabs = true
        let wasWorking = workingTabs.remove(key) != nil, wasFinished = finishedTabs.remove(key) != nil, wasBelled = belledTabs.remove(key) != nil
        tabs.removeTabViewItem(item)
        for pane in moved { destination.bindPane(pane, in: split) }
        destination.tabs.insertTabViewItem(item, at: index); destination.tabs.selectTabViewItem(item)
        if wasWorking { destination.workingTabs.insert(key) }
        if wasFinished { destination.finishedTabs.insert(key) }
        if wasBelled { destination.belledTabs.insert(key) }
        reorderingTabs = false; destination.reorderingTabs = false
        refreshTabs(); destination.refreshTabs()
        destination.window?.layoutIfNeeded()
        destination.restoreTabShares(shares, item: item, split: split)
        // AppKit may lay out the adopted split again after the window is shown.
        DispatchQueue.main.async { [weak destination, weak split, weak item] in
            guard let destination, let split, let item, destination.tabs.indexOfTabViewItem(item) != NSNotFound else { return }
            destination.window?.layoutIfNeeded(); destination.restoreTabShares(shares, item: item, split: split)
        }
        if let focused { destination.window?.makeFirstResponder(focused); if searched == nil { focused.poll() } }
        if destination.window?.isKeyWindow == true { destination.acknowledgeSelectedTab() }
        if tabs.numberOfTabViewItems == 0 { window?.close(); return true }
        // removeTabViewItem selected the next tab while didSelect was suppressed, so acknowledge it here.
        if window?.isKeyWindow == true { acknowledgeSelectedTab() }
        if keepFindFocus { window?.makeFirstResponder(findBar.field) }
        else { window?.makeFirstResponder(selectedPane) }
        return true
    }
    private func restoreTabShares(_ shares: [Double], item: NSTabViewItem, split: NSSplitView) {
        guard tabs.indexOfTabViewItem(item) != NSNotFound, split.arrangedSubviews.count == shares.count else { return }
        split.adjustSubviews()
        setShares(shares, of: split)
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
        let detach = TabMenuItem(title: "Move Tab to New Window", action: #selector(moveTabToNewWindowFromMenu(_:)), keyEquivalent: ""); detach.target = self
        detach.tabs = [item]; detach.isEnabled = canTransferTab(item)
        menu.addItem(detach); menu.addItem(.separator())
        add("Close Tab", [item])
        add("Close Other Tabs", all.filter { $0 !== item })
        add("Close Tabs to the Right", index == NSNotFound ? [] : Array(all.dropFirst(index + 1)))
        return menu
    }
    @objc private func moveTabToNewWindowFromMenu(_ sender: TabMenuItem) {
        guard let item = sender.tabs.first, canTransferTab(item) else { return }
        _ = detachTab(item)
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
    /// Drops a Find target that is leaving this window. Only the departing panes lose their highlights;
    /// the bar stays open for the remaining tabs unless the departing tab was the one on screen.
    private func releaseFind(of departing: [TerminalView], hideBar: Bool) {
        clearFindHighlights(in: departing)
        findTarget = nil; searchedQuery = nil; findBar.status.stringValue = ""
        if hideBar { findBar.isHidden = true; findBarHeight.constant = 0; findBarGap.constant = 0 }
    }
    /// The bar is one per window, and a search can have highlighted any pane, so clear them all.
    private func clearFindHighlights() {
        searchedQuery = nil
        clearFindHighlights(in: panes.map(\.terminal))
    }
    private func clearFindHighlights(in terminals: [TerminalView]) {
        for terminal in terminals {
            _ = try? terminal.session.call("find", ["clear": true])
            terminal.poll()
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
    func windowWillClose(_ notification: Notification) {
        closing = true; tabChips.forEach { $0.cancelDrag() }; cancelTabDrag()
        closeConfirmation.cancel(); for pane in panes { pane.terminal.shutdown() }; app?.remove(self)
    }
}
