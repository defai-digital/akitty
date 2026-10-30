import AppKit

@MainActor final class TerminalPane: NSView {
    private var terminalStorage: TerminalView?
    var terminal: TerminalView { terminalStorage! }
    let status = NSTextField(labelWithString: "Starting shell…")
    init(headless: Bool = false) throws {
        super.init(frame: .zero)
        terminalStorage = try TerminalView(headless: headless)
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
    let tabs = NSTabView()
    private let tabButtons = NSSegmentedControl()
    private let headless: Bool
    private var updateReminder: UpdateReminder?
    weak var app: AkittyApplication?
    private var palette: PaletteController?
    var panes: [TerminalPane] { tabs.tabViewItems.flatMap { ($0.view as? NSSplitView)?.arrangedSubviews.compactMap { $0 as? TerminalPane } ?? [] } }
    var active: TerminalView? { (window?.firstResponder as? TerminalView) ?? (tabs.selectedTabViewItem?.view as? NSSplitView)?.arrangedSubviews.compactMap { ($0 as? TerminalPane)?.terminal }.first }
    init(app: AkittyApplication, headless: Bool = false) throws {
        self.headless = headless
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1000,height: 650), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Akitty"; window.minSize = NSSize(width: 400,height: 250); window.center()
        super.init(window: window)
        window.delegate = self; tabs.delegate = self; tabs.tabViewType = .noTabsNoBorder
        let content = NSView()
        let bar = NSStackView(); bar.orientation = .horizontal; bar.spacing = 6
        tabButtons.segmentStyle = .texturedRounded; tabButtons.trackingMode = .selectOne
        tabButtons.target = self; tabButtons.action = #selector(selectTab(_:))
        tabButtons.setAccessibilityLabel("Terminal tabs")
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New terminal tab")!, target: self, action: #selector(addTab(_:)))
        plus.bezelStyle = .circular; plus.contentTintColor = .labelColor; plus.toolTip = "New tab (⌘T)"; plus.setAccessibilityIdentifier("new-terminal-tab")
        bar.addArrangedSubview(tabButtons); bar.addArrangedSubview(plus)
        for view in [bar, tabs] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 4), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8), bar.heightAnchor.constraint(equalToConstant: 28),
            plus.widthAnchor.constraint(equalToConstant: 30),
            tabs.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4), tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor),
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
        let pane = try TerminalPane(headless: headless); split.addArrangedSubview(pane)
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
        window?.makeFirstResponder(pane.terminal)
    }
    @objc private func addTab(_ sender: Any?) { do { try newTab() } catch { NSAlert(error: error).runModal() } }
    @objc private func selectTab(_ sender: NSSegmentedControl) {
        guard tabs.tabViewItems.indices.contains(sender.selectedSegment) else { return }
        tabs.selectTabViewItem(at: sender.selectedSegment)
    }
    private func refreshTabs() {
        tabButtons.segmentCount = tabs.numberOfTabViewItems
        let width = min(220, max(44, ((window?.contentView?.bounds.width ?? 900) - 60) / CGFloat(max(1, tabs.numberOfTabViewItems))))
        for (index, item) in tabs.tabViewItems.enumerated() { tabButtons.setLabel(item.label, forSegment: index); tabButtons.setWidth(width, forSegment: index) }
        if let selected = tabs.selectedTabViewItem { tabButtons.selectedSegment = tabs.indexOfTabViewItem(selected) }
    }
    func windowDidResize(_ notification: Notification) { refreshTabs() }
    func refreshUpdateReminder(_ version: String?) {
        if let old = updateReminder, let index = window?.titlebarAccessoryViewControllers.firstIndex(of: old) { window?.removeTitlebarAccessoryViewController(at: index) }
        updateReminder = nil
        if let version, let updater = app?.updates { let reminder = UpdateReminder(version: version, updater: updater); window?.addTitlebarAccessoryViewController(reminder); updateReminder = reminder }
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        refreshTabs()
        if let terminal = (tabViewItem?.view as? NSSplitView)?.arrangedSubviews.first as? TerminalPane { window?.makeFirstResponder(terminal.terminal) }
    }
    func perform(_ command: NativeCommand, target: TerminalView? = nil) {
        let terminal = target ?? active
        do {
            switch command {
            case .newWindow: app?.newWindow(nil)
            case .newTab: try newTab()
            case .split: if let split = tabs.selectedTabViewItem?.view as? NSSplitView { try addPane(to: split) }
            case .closePane: if let terminal { close(terminal) }
            case .copy: terminal?.copy(nil)
            case .paste: terminal?.paste(nil)
            case .find: if let terminal { find(terminal) }
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
        guard terminal.snapshot?.exited == true || confirm("Close this terminal?", "Running processes will be stopped.") else { return }
        guard let pane = panes.first(where: { $0.terminal === terminal }), let split = pane.superview as? NSSplitView else { return }
        terminal.shutdown(); split.removeArrangedSubview(pane); pane.removeFromSuperview()
        if split.arrangedSubviews.isEmpty, let item = tabs.tabViewItems.first(where: { $0.view === split }) { tabs.removeTabViewItem(item) }
        refreshTabs()
        if tabs.numberOfTabViewItems == 0 { window?.close() } else { window?.makeFirstResponder(active) }
    }
    private func find(_ terminal: TerminalView) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Find in scrollback"; alert.addButton(withTitle: "Find"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0,y: 0,width: 320,height: 26)); field.placeholderString = "Text to find"; alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            do {
                let data = try terminal.session.call("find", ["text": field.stringValue])
                let found = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["found"] as? Bool ?? false
                terminal.poll(); if !found { terminal.onStatus?("No matching text") }
            } catch { terminal.onStatus?(error.localizedDescription) }
        }
        alert.window.makeFirstResponder(field)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { panes.isEmpty || panes.allSatisfy { $0.terminal.snapshot?.exited == true } || confirm("Close this window?", "All terminal processes in this window will be stopped.") }
    func windowWillClose(_ notification: Notification) { for pane in panes { pane.terminal.shutdown() }; app?.remove(self) }
}
@MainActor private func confirm(_ title: String, _ message: String) -> Bool {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
    alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Close")
    return alert.runModal() == .alertSecondButtonReturn
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

@MainActor public final class AkittyApplication: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindow] = []
    let updates = UpdateController()
    private var settingsWindow: PreferencesWindow?
    public func applicationDidFinishLaunching(_ notification: Notification) {
        updates.onReminderChanged = { [weak self] version in self?.windows.forEach { $0.refreshUpdateReminder(version) } }
        makeMenu(); newWindow(nil); NSApp.activate(ignoringOtherApps: true); updates.start()
    }
    @objc public func newWindow(_ sender: Any?) {
        do { let controller = try TerminalWindow(app: self); windows.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
        catch { NSAlert(error: error).runModal() }
    }
    fileprivate func remove(_ controller: TerminalWindow) { windows.removeAll { $0 === controller } }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if windows.flatMap(\.panes).contains(where: { $0.terminal.snapshot?.exited != true }), !confirm("Quit Akitty?", "All running terminal processes will be stopped.") { return .terminateCancel }
        let group = DispatchGroup()
        for pane in windows.flatMap(\.panes) {
            group.enter(); pane.terminal.shutdown { group.leave() }
        }
        group.notify(queue: .main) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { newWindow(nil) }; return true }
    @objc private func command(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let command = NativeCommand(rawValue: id) else { return }
        if command == .newWindow { newWindow(nil); return }
        (NSApp.keyWindow?.windowController as? TerminalWindow)?.perform(command)
    }
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
        func add(_ command: NativeCommand, key: String, to menu: NSMenu) { let item = menu.addItem(withTitle: command.title, action: #selector(self.command(_:)), keyEquivalent: key); item.target = self; item.representedObject = command.rawValue }
        add(.newWindow,key: "n",to: file); add(.newTab,key: "t",to: file); add(.split,key: "d",to: file); add(.closePane,key: "w",to: file)
        add(.copy,key: "c",to: edit); add(.paste,key: "v",to: edit); add(.find,key: "f",to: edit)
        let paletteItem = view.addItem(withTitle: "Command Palette…", action: #selector(palette(_:)), keyEquivalent: "p"); paletteItem.keyEquivalentModifierMask = [.command,.shift]; paletteItem.target = self
        add(.fontIncrease,key: "+",to: view); add(.fontDecrease,key: "-",to: view); add(.fontReset,key: "0",to: view)
        let window = menu("Window"); NSApp.windowsMenu = window
        window.addItem(withTitle: "Minimize",action: #selector(NSWindow.performMiniaturize(_:)),keyEquivalent: "m")
        window.addItem(withTitle: "Enter Full Screen",action: #selector(NSWindow.toggleFullScreen(_:)),keyEquivalent: "")
    }
}
