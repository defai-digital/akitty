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
@MainActor final class TerminalWindow: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    let tabs = NSTabView()
    private let tabButtons = NSSegmentedControl()
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
        guard panes.contains(where: { $0.terminal === terminal }) else { return }
        if terminal.snapshot?.exited == true { remove(terminal); return }
        guard let window else { return }
        closeConfirmation.present(in: window, title: "Close this terminal?", message: "Running processes will be stopped.") { [weak self, weak terminal] approved in
            if approved, let terminal { self?.remove(terminal) }
        }
    }
    private func remove(_ terminal: TerminalView) {
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
