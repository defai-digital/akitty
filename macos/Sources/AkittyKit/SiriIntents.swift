import AppKit
import AppIntents
import CoreTransferable

public struct AkittyIntents: AppIntentsPackage {}

/// Session identifiers include the app instance: a saved shortcut must never
/// resolve an old pane identifier to a different shell after an app restart.
public struct TerminalEntity: AppEntity, Transferable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "AkiTTY Terminal"
    public static let defaultQuery = TerminalEntityQuery()
    // Also supplies the entity-level policy to the 27.3 preview API, where
    // Siri can retrieve custom entities independently of a foreground action.
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    public let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Reported Status") var reportedStatus: String
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(reportedStatus)")
    }
    var summary: String { "\(name): \(reportedStatus)" }
    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.summary)
    }
    init(id: String, name: String, reportedStatus: String) {
        self.id = id; self.name = name; self.reportedStatus = reportedStatus
    }
}

public struct TerminalEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [TerminalEntity] {
        let entities = try AkittyApplication.intentApplication().terminalEntities()
        return identifiers.compactMap { id in entities.first { $0.id == id } }
    }
    @MainActor public func entities(matching string: String) async throws -> [TerminalEntity] {
        try AkittyApplication.intentApplication().terminalEntities().filter { $0.name.localizedStandardContains(string) }
    }
    @MainActor public func suggestedEntities() async throws -> [TerminalEntity] { try await allEntities() }
    @MainActor public func allEntities() async throws -> [TerminalEntity] {
        try AkittyApplication.intentApplication().terminalEntities()
    }
}

extension AkittyApplication {
    static func intentApplication() throws -> AkittyApplication {
        guard let app = NSApp?.delegate as? AkittyApplication else {
            throw AkittyError.core("Open the installed AkiTTY app before using this action.")
        }
        return app
    }
    func intentID(for terminal: TerminalView) -> String { "\(intentInstance)/\(terminal.session.id)" }
    func terminalEntities() -> [TerminalEntity] {
        windows.flatMap(\.panes).compactMap { pane in
            let terminal = pane.terminal
            guard !terminal.isShutdown else { return nil }
            // Titles and program reports are untrusted. Expose bounded metadata,
            // without indexing scrollback, environment variables or commands.
            let snapshot = terminal.snapshot
            let title = String(ProgramStatusRecord.displayText(snapshot?.title ?? "Terminal").prefix(80))
            let status = snapshot?.program_status?.active.map { "Program reports \($0.state); result not verified" }
                ?? (snapshot?.exited == true ? "Exited" : "No program status reported")
            return TerminalEntity(id: intentID(for: terminal), name: title.isEmpty ? "Terminal" : title, reportedStatus: status)
        }
    }
    func resolveIntentTerminal(_ id: String) throws -> (TerminalWindow, TerminalView) {
        for window in windows {
            if let terminal = window.panes.map(\.terminal).first(where: { !$0.isShutdown && intentID(for: $0) == id }) {
                return (window, terminal)
            }
        }
        throw AkittyError.core("That terminal is no longer open. Choose a current AkiTTY terminal.")
    }
    func focusIntentTerminal(_ id: String) throws {
        let (window, terminal) = try resolveIntentTerminal(id)
        try showIntentWindow(window)
        window.focus(terminal)
    }
    func showIntentWindow(_ window: TerminalWindow) throws {
        try revealQuickTerminalIfNeeded(window)
        window.window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
    }
}

// The 27.3 preview explicitly opts custom actions into Siri's tool catalog.
// The build flag requires the preview SDK and deployment target; older builds
// expose these same actions through App Shortcuts without the new macro.
#if AKITTY_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
public struct NewTerminalIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "New AkiTTY Terminal"
    public static let description = IntentDescription("Open a new terminal window using your configured shell and directory. Does not run a supplied command.")
    public static let openAppWhenRun = true
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<TerminalEntity> {
        try Task.checkCancellation()
        let app = try AkittyApplication.intentApplication()
        let window = try app.createTerminalWindow()
        try app.showIntentWindow(window)
        guard let terminal = window.active, let entity = app.terminalEntities().first(where: { $0.id == app.intentID(for: terminal) }) else {
            throw AkittyError.core("The new terminal is unavailable.")
        }
        return .result(value: entity)
    }
}

#if AKITTY_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
public struct ShowQuickTerminalIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Show AkiTTY Quick Terminal"
    public static let description = IntentDescription("Show the persistent quick terminal. Repeated requests keep it visible and do not hide it.")
    public static let openAppWhenRun = true
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor public func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        try AkittyApplication.intentApplication().showQuickTerminal()
        return .result()
    }
}

#if AKITTY_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
public struct ShowAgentOverviewIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Show AkiTTY Agent Overview"
    public static let description = IntentDescription("Show reported agent activity and terminal input ownership across AkiTTY windows and panes. Reports are not verified results.")
    public static let openAppWhenRun = true
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor public func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        try AkittyApplication.intentApplication().showAgentOverview(nil)
        NSApp.activate(ignoringOtherApps: true)
        return .result()
    }
}

#if AKITTY_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
public struct ListTerminalsIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "List AkiTTY Terminals"
    public static let description = IntentDescription("Find currently open AkiTTY terminal panes and their reported status. Returns current pane references for subsequent actions, without terminal output or command history.")
    public static let openAppWhenRun = true
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<[TerminalEntity]> {
        try Task.checkCancellation()
        return .result(value: try AkittyApplication.intentApplication().terminalEntities())
    }
}

#if AKITTY_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
public struct FocusTerminalIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Focus AkiTTY Terminal"
    public static let description = IntentDescription("Bring an existing AkiTTY terminal pane to the front, including panes in background tabs or the hidden quick terminal.")
    public static let openAppWhenRun = true
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Terminal", description: "The currently open terminal pane to focus.") var terminal: TerminalEntity
    public static var parameterSummary: some ParameterSummary { Summary("Focus \(\.$terminal)") }
    @MainActor public func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        try AkittyApplication.intentApplication().focusIntentTerminal(terminal.id)
        return .result()
    }
}

#if AKITTY_SIRI_AI_PREVIEW
@AppIntent(.tool)
#endif
public struct RequestCommandIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Request AkiTTY Command"
    public static let description = IntentDescription("Request one shell command in a chosen terminal. Always shows the exact command and target in AkiTTY for human approval. Requires an idle integrated shell. Dispatch does not establish completion; never retry an uncertain dispatch automatically. Does not send a task to a coding agent.")
    public static let openAppWhenRun = true
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Terminal", description: "The currently open terminal pane whose idle integrated shell should receive the approved command.") var terminal: TerminalEntity
    @Parameter(title: "Command", description: "One exact shell command, at most 4096 UTF-8 bytes, without line breaks or invisible control characters. The person must approve it in AkiTTY.", requestValueDialog: "What command should AkiTTY request?") var command: String
    public static var parameterSummary: some ParameterSummary { Summary("Request \(\.$command) in \(\.$terminal)") }
    @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        let app = try AkittyApplication.intentApplication()
        let (_, view) = try app.resolveIntentTerminal(terminal.id)
        try app.focusIntentTerminal(terminal.id)
        try await app.requestSiriCommand(command, in: view)
        return .result(dialog: "Command dispatched after approval. Review the terminal for results, then reclaim terminal control. Completion has not been verified.")
    }
}

