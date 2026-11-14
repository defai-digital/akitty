import AppKit
import AppIntents

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

@MainActor public final class AkittyApplication: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var windows: [TerminalWindow] = []
    let intentInstance = UUID().uuidString
    private var eventMenuItem: NSMenuItem?
    private var windowLayoutsMenu: NSMenu?
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
    /// Delegates that rebuild the profile submenus each time they open, so they always list the saved profiles.
    private var profileMenus: [ProfileMenu] = []
    /// Opens a window, or a tab in the key terminal window, whose first pane uses `profile` (nil: defaults).
    func open(profile: UUID?, asTab: Bool) {
        do {
            if asTab, let window = NSApp.keyWindow?.windowController as? TerminalWindow ?? intentWindow() { try window.newTab(profile: profile, copyDirectory: false); window.showWindow(nil) }
            else { try createTerminalWindow(profile: profile) }
        } catch { NSAlert(error: error).runModal() }
    }
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
    @discardableResult func createTerminalWindow(directory: String? = nil, headless: Bool = false, profile: UUID? = nil) throws -> TerminalWindow {
        let controller = try TerminalWindow(app: self, headless: headless, directory: directory, profile: profile)
        windows.append(controller)
        if !launched { openedFolderAtLaunch = true }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }
    /// The windows a layout may capture: every regular window, never the quick terminal.
    private var regularWindows: [TerminalWindow] { windows.filter { $0 !== quickTerminal.terminalWindow } }
    /// Saves regular windows. Text capture is explicitly opt-in; processes always start fresh.
    func saveLayout(named name: String, includeScrollback: Bool = false) throws {
        guard WindowLayoutStore.validatedName(name) != nil else { throw WindowLayoutError.invalidName }
        let captured = try regularWindows.map { try $0.captureLayout(includeScrollback: includeScrollback) }
        guard !captured.isEmpty else { throw WindowLayoutError.noWindows }
        guard WindowLayoutStore.upsert(WindowLayout(name: name, windows: captured)) else { throw WindowLayoutError.tooLarge }
    }
    /// Opens every window in the layout as a new window, leaving open windows alone.
    /// `headless` lets tests exercise restoration without starting real shells.
    func openLayout(_ layout: WindowLayout, headless: Bool = false) throws {
        for saved in layout.windows {
            let controller = try TerminalWindow.restored(app: self, headless: headless, layout: saved)
            windows.append(controller)
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
    }
    func remove(_ controller: TerminalWindow) { quickTerminal.closed(controller); windows.removeAll { $0 === controller } }
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
    @objc private func settings(_ sender: Any?) { showSettings() }
    func showSettings(tab: SettingsTab? = nil) {
        if settingsWindow == nil { settingsWindow = PreferencesWindow(updater: updates) }
        if let tab { settingsWindow?.select(tab) }
        settingsWindow?.showWindow(nil); settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    private var alertHost: NSWindow? { NSApp.keyWindow ?? windows.first?.window }
    /// Rebuilt every time the submenu opens so it always reflects the store, including layouts saved or deleted here.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === windowLayoutsMenu else { return }
        menu.removeAllItems(); menu.autoenablesItems = false
        let save = menu.addItem(withTitle: "Save Windows as Layout…", action: #selector(saveLayoutFromMenu(_:)), keyEquivalent: "")
        save.target = self; save.isEnabled = !regularWindows.isEmpty
        menu.addItem(.separator())
        let layouts = WindowLayoutStore.load()
        if layouts.isEmpty {
            menu.addItem(withTitle: "No Saved Layouts", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for layout in layouts {
                let item = menu.addItem(withTitle: layout.name, action: #selector(openSavedLayout(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = layout.name
            }
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Remove Stored Scrollback", action: nil, keyEquivalent: "")
        let clearMenu = NSMenu(title: "Remove Stored Scrollback")
        for layout in layouts where layout.windows.contains(where: { $0.tabs.contains(where: { $0.panes.contains(where: { $0.scrollback != nil }) }) }) {
            let item = clearMenu.addItem(withTitle: layout.name, action: #selector(removeSavedScrollback(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = layout.name
        }
        clear.isEnabled = !clearMenu.items.isEmpty; clear.submenu = clearMenu
        let delete = menu.addItem(withTitle: "Delete Layout", action: nil, keyEquivalent: "")
        let deleteMenu = NSMenu(title: "Delete Layout")
        if layouts.isEmpty {
            deleteMenu.addItem(withTitle: "No Saved Layouts", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for layout in layouts {
                let item = deleteMenu.addItem(withTitle: layout.name, action: #selector(deleteSavedLayout(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = layout.name
            }
        }
        delete.submenu = deleteMenu
    }
    @objc private func saveLayoutFromMenu(_ sender: Any?) {
        guard !regularWindows.isEmpty, let window = alertHost else { return }
        let (alert, field, history) = Self.layoutSaveAlert(name: nextLayoutName())
        alert.beginSheetModal(for: window) { [weak self, field, history] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.confirmSaveLayout(named: field.stringValue, includeScrollback: history.state == .on, in: window)
        }
    }
    static func layoutSaveAlert(name: String) -> (NSAlert, NSTextField, NSButton) {
        let alert = NSAlert()
        alert.messageText = "Save Windows as Layout"
        alert.informativeText = "Save every open window, tab and split with each pane's starting folder. Optional recent text is stored locally and may contain sensitive output. Each pane opens a fresh shell."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = name; field.setAccessibilityLabel("Layout name")
        let history = NSButton(checkboxWithTitle: "Include recent scrollback", target: nil, action: nil)
        history.state = .off
        let accessory = NSStackView(views: [field, history]); accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 280, height: 58)
        alert.accessoryView = accessory; alert.window.initialFirstResponder = field
        return (alert, field, history)
    }
    private func confirmSaveLayout(named rawName: String, includeScrollback: Bool, in window: NSWindow) {
        guard let name = WindowLayoutStore.validatedName(rawName) else { NSAlert(error: WindowLayoutError.invalidName).runModal(); return }
        let exists = WindowLayoutStore.load().contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard exists else { persistLayout(named: name, includeScrollback: includeScrollback); return }
        let alert = NSAlert(); alert.messageText = "Replace “\(name)”?"
        alert.informativeText = "A saved layout with this name already exists."
        alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in if response == .alertFirstButtonReturn { self?.persistLayout(named: name, includeScrollback: includeScrollback) } }
    }
    private func persistLayout(named name: String, includeScrollback: Bool) {
        do { try saveLayout(named: name, includeScrollback: includeScrollback) } catch { NSAlert(error: error).runModal() }
    }
    @objc private func removeSavedScrollback(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let window = alertHost else { return }
        let alert = NSAlert(); alert.messageText = "Remove stored scrollback from “\(name)”?"
        alert.informativeText = "The layout and open terminals are kept. Future openings will start without the saved text."
        alert.addButton(withTitle: "Remove Scrollback"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do { try WindowLayoutStore.removeScrollback(named: name) } catch { NSAlert(error: error).runModal() }
        }
    }
    /// The first unused "Layout N", so the prefilled name does not immediately ask to replace an existing one.
    private func nextLayoutName() -> String {
        let names = Set(WindowLayoutStore.load().map { $0.name.lowercased() })
        var number = 1
        while names.contains("layout \(number)") { number += 1 }
        return "Layout \(number)"
    }
    @objc private func openSavedLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let layout = WindowLayoutStore.load().first(where: { $0.name == name }) else { return }
        do { try openLayout(layout) } catch { NSAlert(error: error).runModal() }
    }
    @objc private func deleteSavedLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let alert = NSAlert(); alert.messageText = "Delete “\(name)”?"
        alert.informativeText = "The saved layout is removed. Open windows are not affected."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        if let window = alertHost {
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { WindowLayoutStore.delete(named: name) } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            WindowLayoutStore.delete(named: name)
        }
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
        let layouts = NSMenuItem(title: "Window Layouts", action: nil, keyEquivalent: "")
        let layoutsMenu = NSMenu(title: "Window Layouts"); layoutsMenu.delegate = self
        layouts.submenu = layoutsMenu; file.addItem(layouts); windowLayoutsMenu = layoutsMenu
        file.addItem(.separator())
        for (title, kind) in [("New Window with Profile", ProfileMenu.Kind.window), ("New Tab with Profile", .tab)] {
            let item = file.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title), owner = ProfileMenu(app: self, kind: kind)
            submenu.delegate = owner; profileMenus.append(owner); item.submenu = submenu
        }
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

/// Fills a New Window/Tab with Profile submenu from the saved profiles when it opens.
@MainActor final class ProfileMenu: NSObject, NSMenuDelegate {
    enum Kind { case window, tab }
    private weak var app: AkittyApplication?
    private let kind: Kind
    init(app: AkittyApplication, kind: Kind) { self.app = app; self.kind = kind }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let defaults = menu.addItem(withTitle: "Default Settings", action: #selector(choose(_:)), keyEquivalent: ""); defaults.target = self
        let profiles = TerminalPreferences.load().profiles
        if !profiles.isEmpty { menu.addItem(.separator()) }
        for profile in profiles {
            let item = menu.addItem(withTitle: profile.name, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = profile.id
        }
        menu.addItem(.separator())
        let edit = menu.addItem(withTitle: "Edit Profiles…", action: #selector(editProfiles(_:)), keyEquivalent: ""); edit.target = self
    }
    @objc private func choose(_ sender: NSMenuItem) { app?.open(profile: sender.representedObject as? UUID, asTab: kind == .tab) }
    @objc private func editProfiles(_ sender: Any?) { app?.showSettings(tab: .profiles) }
}
