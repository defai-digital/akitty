import AppKit
import AgentIPC
import AppIntents
import UniformTypeIdentifiers

/// Folders requested by an open-documents event: Finder "Open With", a Dock drop, or `open -a Akitty <path>` (how
/// AX Code Desktop hands a project over). An ordinary file opens in its folder, including a `.command` or `.tool`
/// file that is not executable. `documentOpen` offers to run a Unix executable or an executable script. Missing
/// paths, non-file URLs and anything past `limit` are counted as skipped rather than dropped silently, and the limit
/// keeps one event from starting an unbounded number of shells.
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
    private var requestsMenuItem: NSMenuItem?
    private var windowLayoutsMenu: NSMenu?
    private(set) lazy var agentRequests: AgentRequests = {
        let requests = AgentRequests(source: { [weak self] in self?.windows.flatMap(\.panes).map(\.terminal) ?? [] })
        requests.onFailure = { [weak self] message in self?.eventMenuItem?.title = "Agent Event Timeline (recording warning)…"; self?.eventMenuItem?.toolTip = message }
        return requests
    }()
    func registerAgentTerminal(_ terminal: TerminalView) {
        agentRequests.register(terminal)
        terminal.appEntityIdentifier = EntityIdentifier(for: TerminalEntity.self, identifier: intentID(for: terminal))
    }
    @objc private func toggleAgentRequests(_ sender: NSMenuItem) {
        do { try setAgentRequests(!agentRequests.enabled) } catch { NSAlert(error: error).runModal() }
    }
    /// Turns Local Agent Requests on or off and keeps the menu checkmark in step (Settings uses this too).
    func setAgentRequests(_ enabled: Bool) throws {
        defer {
            requestsMenuItem?.state = agentRequests.enabled ? .on : .off
            NotificationCenter.default.post(name: .agentRequestsChanged, object: nil)
        }
        try agentRequests.setEnabled(enabled)
    }
    @objc private func showAgentTimeline(_ sender: Any?) { agentRequests.showTimeline() }
    /// Settings → Agents installs, repairs or removes each agent's hooks and shows what is connected.
    @objc private func showAgentIntegrations(_ sender: Any?) { showSettings(tab: .agents) }
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

    // MARK: Workspace restore

    private var workspaceTimer: Timer?
    /// Where the workspace and its restore setting live; tests pass their own suite.
    var workspaceDefaults = UserDefaults.standard
    /// Saves the open windows and each pane's last reported agent conversation when restore is on. Never text.
    func saveWorkspace() {
        guard WorkspaceStore.isEnabled(workspaceDefaults), allowsTabTransfer else { return }
        let captured = regularWindows.map { $0.captureLayout(conversation: { [weak self] in self?.agentRequests.conversation(for: $0) }) }
        WorkspaceStore.save(WindowLayout(name: "Workspace", windows: captured), workspaceDefaults)
    }
    /// Reopens the saved workspace at launch. Each pane starts a fresh shell; a pane that had an agent conversation
    /// only offers to resume it. Returns false when restore is off or nothing was saved.
    func restoreWorkspaceIfEnabled(headless: Bool = false) throws -> Bool {
        guard WorkspaceStore.isEnabled(workspaceDefaults), var layout = WorkspaceStore.load(workspaceDefaults) else { return false }
        for window in layout.windows.indices {
            for tab in layout.windows[window].tabs.indices {
                for pane in layout.windows[window].tabs[tab].panes.indices {
                    let saved = layout.windows[window].tabs[tab].panes[pane]
                    layout.windows[window].tabs[tab].panes[pane].scrollback = saved.agent.map(WorkspaceStore.notice(for:))
                }
            }
        }
        for saved in layout.windows {
            let controller = try TerminalWindow.restored(app: self, headless: headless, layout: saved)
            windows.append(controller)
            // Pair tab by tab, so a pane that could not be recreated never shifts another pane's conversation onto it.
            for (item, tab) in zip(controller.tabs.tabViewItems, saved.tabs) {
                let panes = (item.view as? NSSplitView)?.arrangedSubviews.compactMap { $0 as? TerminalPane } ?? []
                guard panes.count == tab.panes.count else { continue }
                for (pane, record) in zip(panes, tab.panes) {
                    if let conversation = record.agent { agentRequests.offerResume(conversation, in: pane.terminal) }
                }
            }
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
        if !launched { openedFolderAtLaunch = true }
        return true
    }
    private func startWorkspaceAutosave() {
        agentRequests.onAgentSessionReport = { [weak self] in self?.saveWorkspace() }
        // A crash or forced quit keeps what was saved most recently.
        workspaceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.saveWorkspace() } }
    }
    @objc private func toggleWorkspaceRestore(_ sender: NSMenuItem) {
        WorkspaceStore.setEnabled(!WorkspaceStore.isEnabled(workspaceDefaults), workspaceDefaults)
        sender.state = WorkspaceStore.isEnabled(workspaceDefaults) ? .on : .off
        saveWorkspace()
    }
    /// Clearing also turns the option off; otherwise the next autosave would write the workspace straight back.
    @objc private func clearSavedWorkspace(_ sender: Any?) { WorkspaceStore.setEnabled(false, workspaceDefaults) }
    /// Resumes the focused pane's restored agent conversation, at the human's request.
    @objc func resumeAgentConversation(_ sender: Any?) {
        // Only the pane that has keyboard focus: never a guess at another pane in the tab.
        guard let terminal = (NSApp.keyWindow?.windowController as? TerminalWindow)?.window?.firstResponder as? TerminalView else {
            let alert = NSAlert(); alert.messageText = "Click the terminal pane to resume first."
            alert.informativeText = "Or select the pane in Agent Overview and choose Resume Conversation."; alert.runModal(); return
        }
        do { try agentRequests.resume(in: terminal) } catch { NSAlert(error: error).runModal() }
    }
    let updates = UpdateController()
    private var settingsWindow: PreferencesWindow?
    /// Reads the current handler for a type. Tests replace this; the menu action still changes the real handler.
    var defaultTerminalApplication: (UTType) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    /// Programs and skipped-item counts delivered before the app finished launching. Shown after the menu exists.
    private var pendingOpen: DocumentOpen?
    /// Timers that type an approved program once its shell prompt is up.
    private var launchTimers: [Timer] = []
    /// `duplicateKey`s of programs whose Run confirmation is open, and of those waiting to be typed into their shell.
    private var confirmingRunnables: Set<String> = []
    private var launchingRunnables: Set<String> = []
    /// True while the default-terminal change waits for the macOS confirmations.
    private(set) var settingDefaultTerminal = false
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
            agentOverview = AgentOverviewController(source: { [weak self] in self?.windows ?? [] }, requestsEnabled: { [weak self] in self?.agentRequests.enabled == true },
                                                   pending: { [weak self] in self?.agentRequests.pendingSummary(for: $0) },
                                                   agentSession: { [weak self] in self?.agentRequests.describeConversation(for: $0) },
                                                   resume: { [weak self] terminal in try self?.agentRequests.resume(in: terminal) }) { [weak self] window, terminal in
                // A hidden quick terminal is shown through its controller so its hide and focus restore keep working.
                if window === self?.quickTerminal.terminalWindow, window.window?.isVisible != true {
                    do { try self?.quickTerminal.toggle() } catch { NSAlert(error: error).runModal() }
                }
                window.focus(terminal)
            }
        }
        agentOverview?.showWindow(nil); agentOverview?.window?.makeKeyAndOrderFront(nil)
    }
    private(set) var globalFind: GlobalFindController?
    func showGlobalFind(anchor: TerminalWindow?) {
        if globalFind == nil { globalFind = GlobalFindController(app: self) }
        globalFind?.show(anchor: anchor)
    }
    /// Shows a hidden quick terminal, then selects the tab and focuses that pane.
    func revealTerminal(_ terminal: TerminalView) {
        guard let window = windows.first(where: { $0.panes.contains { $0.terminal === terminal } }) else { return }
        try? revealQuickTerminalIfNeeded(window)
        window.focus(terminal)
    }
    private var launched = false
    private var openedFolderAtLaunch = false
    private enum TerminationState { case idle, confirming, closing }
    private var terminationState = TerminationState.idle
    var allowsTabTransfer: Bool { if case .idle = terminationState { return true }; return false }
    private let quitConfirmation = CloseConfirmation()
    public func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        agentRequests.startRecording()
        updates.onReminderChanged = { [weak self] version in self?.windows.forEach { $0.refreshUpdateReminder(version) } }
        makeMenu()
        startWorkspaceAutosave()
        // Only when the person chose it in Settings → Agents; otherwise requests start off, as before.
        if AgentRequestsLaunchSetting.isOn() {
            do { try setAgentRequests(true) } catch { NSAlert(error: error).runModal() }
        }
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
        finishPendingOpens()
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
        do { if !(try restoreWorkspaceIfEnabled(headless: headless)) { try createTerminalWindow(headless: headless) } } catch { NSAlert(error: error).runModal(); return false }
        return true
    }
    public func application(_ sender: NSApplication, open urls: [URL]) {
        let request = documentOpen(from: urls)
        for directory in request.folders.directories { newWindow(directory: directory) }
        // A confirmation during launch runs before the menu and the Dock exist, and the alert can sit behind Finder.
        // Hold programs until didFinishLaunching has activated the app.
        if !launched {
            var pending = pendingOpen ?? DocumentOpen()
            pending.merge(request)
            pendingOpen = pending
            if !request.runnable.isEmpty { openedFolderAtLaunch = true }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        presentOpens(request.runnable, skipped: request.folders.skipped + request.skippedRunnables, openWindowIfNone: false)
    }
    /// Confirms each program, then offers a normal window when a cold launch was cancelled and nothing else opened.
    private func presentOpens(_ paths: [String], skipped: Int, openWindowIfNone: Bool) {
        let before = windows.count
        for path in paths {
            // A program opened again while it is being confirmed or waits for its prompt (a repeated double-click)
            // is asked about and run once.
            let key = DefaultTerminal.duplicateKey(path)
            guard !confirmingRunnables.contains(key), !launchingRunnables.contains(key) else { continue }
            confirmingRunnables.insert(key)
            openRunnable(at: path, key: key)
            confirmingRunnables.remove(key)
        }
        if skipped > 0 {
            let alert = NSAlert(); alert.messageText = skipped == 1 ? "One item was not opened." : "\(skipped) items were not opened."
            alert.informativeText = "Akitty opens existing folders and programs, at most 8 from one request."; alert.runModal()
        }
        if openWindowIfNone, windows.count == before, windows.isEmpty { _ = openUntitledWindow() }
    }
    private func finishPendingOpens() {
        guard let pending = pendingOpen else { return }
        pendingOpen = nil
        NSApp.activate(ignoringOtherApps: true)
        presentOpens(pending.runnable, skipped: pending.folders.skipped + pending.skippedRunnables, openWindowIfNone: true)
    }
    /// Asks before running a program Finder opened, then types its quoted path into a new shell in its folder.
    /// Open Folder starts the same shell without running anything, as `open -a Akitty <file>` did for other files.
    private func openRunnable(at path: String, key: String) {
        let folder = (path as NSString).deletingLastPathComponent
        // When the file cannot be run, its folder can still be opened, as before this file type was handled.
        guard DefaultTerminal.launchLine(for: path) != nil else {
            // The path is not shown: the characters that made it unsafe would rewrite this alert too.
            return offerFolder(folder, "Cannot Run This File", "This file's path contains hidden or control characters, so Akitty will not run it or show its name.")
        }
        let shell = DefaultTerminal.resolvedShell(TerminalPreferences.load().effective(profile: nil).shell)
        guard DefaultTerminal.launchShell(shell) != nil else {
            return offerFolder(folder, "Cannot Run This File", "Akitty runs programs from Finder in sh, bash, zsh, dash, ksh or fish. The shell in Settings is \((shell as NSString).lastPathComponent).\n\n\(path)")
        }
        guard let identity = DefaultTerminal.fileIdentity(path) else {
            return warn("Cannot Run This File", "Akitty cannot find this file.")
        }
        let alert = NSAlert()
        alert.messageText = "Allow Akitty to run “\((path as NSString).lastPathComponent)”?"
        alert.informativeText = "A new terminal will start in this file's folder and run it after the prompt. The shell stays open afterward.\n\n\(path)"
        alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Open Folder"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn: newWindow(directory: folder); return
        default: return
        }
        guard DefaultTerminal.fileIdentity(path) == identity else {
            return warn("The File Changed", "Akitty did not run it, because the file changed while the confirmation was open.")
        }
        do {
            let controller = try createTerminalWindow(directory: folder)
            guard let terminal = controller.active else { return }
            // The pane's own shell decides the quoting. Settings could have changed while the alert was open.
            guard let kind = DefaultTerminal.launchShell(terminal.shellPath), let line = DefaultTerminal.launchLine(for: path, shell: kind) else {
                return warn("Cannot Run This File", "Akitty does not type programs into \((terminal.shellPath as NSString).lastPathComponent). The shell is open in the file's folder.")
            }
            sendLaunchLine(line, path: path, key: key, identity: identity, to: terminal)
        } catch { NSAlert(error: error).runModal() }
    }
    /// Mutable state for one pending launch. Main-actor isolated so the timer closure can hold it.
    @MainActor private final class LaunchWait {
        var clock: DefaultTerminal.LaunchClock
        init(now: TimeInterval) { clock = DefaultTerminal.LaunchClock(now: now) }
    }
    private func offerFolder(_ folder: String, _ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Folder"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { newWindow(directory: folder) }
    }
    private func warn(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }
    /// Types `line` once shell integration reports a prompt, or after two seconds when integration is off.
    /// Nothing is sent when the person has typed in the pane, the prompt was edited, or the file changed since Run.
    private func sendLaunchLine(_ line: String, path: String, key: String, identity: DefaultTerminal.FileIdentity, to terminal: TerminalView) {
        let wait = LaunchWait(now: ProcessInfo.processInfo.systemUptime)
        launchingRunnables.insert(key)
        let typed = terminal.inputCount
        let name = (path as NSString).lastPathComponent
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak terminal] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                @MainActor func finish() {
                    timer.invalidate(); self.launchTimers.removeAll { $0 === timer }; self.launchingRunnables.remove(key)
                }
                guard let terminal, !terminal.isShutdown else { finish(); return }
                // Another confirmation, or a sheet on this window such as Close, holds the launch and pauses its clock.
                // Nothing is sent into a closing pane, and no notice stacks on top of another alert.
                let held = NSApp.modalWindow != nil || terminal.window?.attachedSheet != nil
                let elapsed = wait.clock.tick(now: ProcessInfo.processInfo.systemUptime, paused: held)
                if held { return }
                let state = try? terminal.session.shellState()
                if state?.exited == true {
                    finish()
                    return self.warn("“\(name)” Did Not Run", "The shell exited before its prompt was ready, so Akitty did not type the command.")
                }
                let step = DefaultTerminal.launchStep(ready: state?.shell?.ready == true, integrated: terminal.shellIntegrated, elapsed: elapsed)
                switch step {
                case .wait: return
                case .timedOut:
                    finish()
                    self.warn("“\(name)” Did Not Run", "The shell did not report its prompt within \(Int(DefaultTerminal.integratedTimeout)) seconds, so Akitty did not type the command. A startup question may be waiting, or shell integration may be unavailable in this shell (for example, another DEBUG trap). The shell is open in the file's folder.")
                case .send:
                    finish()
                    guard terminal.inputCount == typed, !terminal.hasMarkedText(), state?.control?.prompt_edited != true else {
                        return self.warn("“\(name)” Did Not Run", "Text was typed in the new terminal before its prompt was ready, so Akitty did not add the command to it.")
                    }
                    guard DefaultTerminal.fileIdentity(path) == identity else {
                        return self.warn("“\(name)” Did Not Run", "The file changed after you chose Run, so Akitty did not run it.")
                    }
                    // Ctrl-U first, as agent commands do: a terminal report that reached the line editor cannot prefix the path.
                    terminal.send("\u{15}" + line)
                }
            }
        }
        launchTimers.append(timer)
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc public func newWindow(_ sender: Any?) { newWindow(directory: nil) }
    /// Dock menu. macOS adds the open-window list, Options, Show All Windows, Hide and Quit after these items.
    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let window = menu.addItem(withTitle: "New Window", action: #selector(newWindowFromDock(_:)), keyEquivalent: "")
        window.target = self
        let tab = menu.addItem(withTitle: "New Tab", action: #selector(newTabFromDock(_:)), keyEquivalent: "")
        tab.target = self
        return menu
    }
    @objc func newWindowFromDock(_ sender: Any?) { newWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    /// A tab in the frontmost terminal. Settings and Agent Overview are skipped. A hidden quick terminal is not revealed.
    /// With none open, this is a new window.
    @objc func newTabFromDock(_ sender: Any?) {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? TerminalWindow }
        if let window = Self.dockTabWindow(orderedFrontToBack: ordered, quick: quickTerminal.terminalWindow) {
            do { try window.newTab(); window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil) }
            catch { NSAlert(error: error).runModal() }
        } else { newWindow(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
    /// `orderedFrontToBack` is the app's terminal windows, front first. The first visible one wins.
    /// When every regular window is minimized, the frontmost regular window is still used so the tab is not lost.
    static func dockTabWindow(orderedFrontToBack: [TerminalWindow], quick: TerminalWindow?,
                              isVisible: @MainActor (TerminalWindow) -> Bool = { $0.window?.isVisible == true }) -> TerminalWindow? {
        if let visible = orderedFrontToBack.first(where: isVisible) { return visible }
        return orderedFrontToBack.first { $0 !== quick }
    }
    func createInitialWindowIfNeeded(defaultLaunch: Bool, headless: Bool = false) throws {
        if !openedFolderAtLaunch && defaultLaunch, !(try restoreWorkspaceIfEnabled(headless: headless)) { try createTerminalWindow(headless: headless) }
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
    /// An empty destination avoids spawning a temporary shell and keeps the moved session's opaque IDs.
    @discardableResult func moveTabToNewWindow(_ item: NSTabViewItem, from source: TerminalWindow, at point: NSPoint? = nil) throws -> TerminalWindow? {
        guard windows.contains(where: { $0 === source }), source.canTransferTab(item) else { return nil }
        // The window's opened folder and profile are defaults for new splits and tabs, so they travel too.
        let destination = try TerminalWindow(app: self, headless: source.headless, directory: source.directory, profile: source.profile, createInitialTab: false)
        // Capture geometry while the source still owns its last tab and display.
        if let window = destination.window, let original = source.window?.frame {
            var frame = original
            if let point { frame.origin = NSPoint(x: point.x - min(120, frame.width / 2), y: point.y - frame.height + 40) }
            else { frame.origin.x += 30; frame.origin.y -= 30 }
            let screen = point.flatMap { location in NSScreen.screens.first { $0.frame.contains(location) } } ?? source.window?.screen ?? NSScreen.main
            window.setFrame(window.constrainFrameRect(frame, to: screen), display: false)
        }
        windows.append(destination)
        guard source.transferTab(item, to: destination, at: 0) else { destination.window?.close(); return nil }
        destination.showWindow(nil); destination.window?.makeKeyAndOrderFront(nil)
        return destination
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
        saveWorkspace()
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
        if command == .findAll {
            showGlobalFind(anchor: (keyWindow?.windowController as? TerminalWindow) ?? windows.first { $0.window?.isVisible == true })
            return
        }
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
    /// Sets this app as the handler for Unix executables and Terminal shell scripts.
    /// macOS asks the user to confirm each change.
    /// Only types another app still handles are changed. The item is disabled while a change is in progress.
    @objc func setAsDefaultTerminal(_ sender: Any?) {
        guard !settingDefaultTerminal else { return }
        let types = defaultTerminalTypesToChange()
        guard !types.isEmpty else { return }
        settingDefaultTerminal = true
        setDefaultTerminal(types, at: Bundle.main.bundleURL, failures: [])
    }
    func defaultTerminalTypesToChange() -> [UTType] {
        let types = [UTType.unixExecutable] + (DefaultTerminal.shellScriptType.map { [$0] } ?? [])
        return types.filter { !DefaultTerminal.isHandler(defaultTerminalApplication($0), for: Bundle.main.bundleURL) }
    }
    private func setDefaultTerminal(_ types: [UTType], at bundle: URL, failures: [String]) {
        guard let type = types.first else {
            settingDefaultTerminal = false
            guard !failures.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Failed to Set Default Terminal"
            alert.informativeText = "Akitty could not be set as the default terminal.\n\n\(failures.joined(separator: "\n"))"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: bundle, toOpen: type) { [weak self] error in
            // Declining one confirmation declines the change: no further prompt and no failure alert.
            let cancelled = error.map(DefaultTerminal.isUserCancel) ?? false
            let failure = error?.localizedDescription
            DispatchQueue.main.async {
                guard !cancelled else { self?.settingDefaultTerminal = false; return }
                self?.setDefaultTerminal(Array(types.dropFirst()), at: bundle, failures: failures + (failure.map { [$0] } ?? []))
            }
        }
    }
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
        let restore = menu.addItem(withTitle: "Reopen Windows and Agent Conversations at Launch", action: #selector(toggleWorkspaceRestore(_:)), keyEquivalent: "")
        restore.target = self; restore.state = WorkspaceStore.isEnabled(workspaceDefaults) ? .on : .off
        let clearWorkspace = menu.addItem(withTitle: "Clear Saved Workspace", action: #selector(clearSavedWorkspace(_:)), keyEquivalent: "")
        clearWorkspace.target = self; clearWorkspace.isEnabled = workspaceDefaults.data(forKey: WorkspaceStore.workspaceKey) != nil
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
        requestsMenuItem = requests
        let timeline = app.addItem(withTitle: "Agent Event Timeline…", action: #selector(showAgentTimeline(_:)), keyEquivalent: ""); timeline.target = self
        let integrations = app.addItem(withTitle: "Agent Integrations…", action: #selector(showAgentIntegrations(_:)), keyEquivalent: ""); integrations.target = self
        eventMenuItem = timeline
        let export = app.addItem(withTitle: "Export Agent Events…", action: #selector(exportAgentEvents(_:)), keyEquivalent: ""); export.target = self
        let defaultTerminal = app.addItem(withTitle: "Make Akitty the Default Terminal", action: #selector(setAsDefaultTerminal(_:)), keyEquivalent: "")
        defaultTerminal.target = self
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
        let resume = file.addItem(withTitle: "Resume Agent Conversation", action: #selector(resumeAgentConversation(_:)), keyEquivalent: ""); resume.target = self
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
        add(.findAll, key: "f", modifiers: [.command, .option], to: edit)
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

extension AkittyApplication: NSMenuItemValidation {
    /// The app menu keeps automatic validation on, so Check for Updates and the rest still validate themselves.
    /// Only the default-terminal item is decided here. Every other item keeps the enabled state its menu already set.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setAsDefaultTerminal(_:)) {
            // Enabled until both types are handled here, so a half-finished change can be completed.
            return !settingDefaultTerminal && !defaultTerminalTypesToChange().isEmpty
        }
        return item.isEnabled
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
