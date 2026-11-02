import AppKit

public struct AgentCommandRequest: Sendable {
    public let sessionID: UInt64
    public let actor: String
    public let command: String
    /// Untrusted shell metadata, displayed for context only.
    public let cwd: String?
}
public struct AgentDispatch: Decodable, Sendable {
    public let accepted: Bool
    public let after_command_id: UInt64
    public let completion_untrusted: Bool
}
public struct ControlSummary: Codable, Sendable {
    public let owner: String
    public let agent: Bool
    public let audit_seq: UInt64
}

extension TerminalSession {
    private struct Lease: Decodable { let lease: UInt64 }
    private struct Authorization: Decodable { let authorization: UInt64 }
    public func acquireControl(actor: String) throws -> UInt64 {
        try JSONDecoder().decode(Lease.self, from: call("control_acquire", ["actor":actor])).lease
    }
    public func releaseControl(_ lease: UInt64) throws { _ = try call("control_release", ["lease":lease]) }
    public func reclaimControl() throws { _ = try call("control_reclaim") }
    public func denyCommand(lease: UInt64) throws { _ = try call("command_deny", ["lease":lease]) }
    /// Trusted host entry. Call only after explicit UI approval or host policy authorization.
    public func authorizeCommand(lease: UInt64, command: String, expectedDirectory: String?) throws -> UInt64 {
        var fields: [String:Any] = ["lease":lease,"command":command]
        if let expectedDirectory { fields["expected_cwd"] = expectedDirectory }
        return try JSONDecoder().decode(Authorization.self, from: call("command_authorize",fields)).authorization
    }
    public func executeCommand(lease: UInt64, authorization: UInt64, command: String) throws -> AgentDispatch {
        let receipt = try JSONDecoder().decode(AgentDispatch.self, from: call("command_execute", ["lease":lease,"authorization":authorization,"command":command]))
        guard receipt.accepted, receipt.completion_untrusted else { throw AkittyError.core("Invalid command dispatch receipt.") }
        return receipt
    }
    /// Bounded, session-local audit. A host needing durable records must persist every page and detect eviction.
    public func controlAudit(after: UInt64 = 0) throws -> Data { try call("control_audit", ["after":after]) }
}

/// Host policy and PTY authority remain separate from program status and terminal text.
@MainActor public final class AgentCommandHost {
    private let session: TerminalSession
    private let dispatch: (UInt64, UInt64, String) throws -> AgentDispatch
    private let release: (UInt64) throws -> Void
    public init(session: TerminalSession) {
        self.session = session; dispatch = { try session.executeCommand(lease: $0, authorization: $1, command: $2) }
        release = { try session.releaseControl($0) }
    }
    init(session: TerminalSession, dispatch: @escaping (UInt64, UInt64, String) throws -> AgentDispatch, release: ((UInt64) throws -> Void)? = nil) {
        self.session = session; self.dispatch = dispatch
        self.release = release ?? { try session.releaseControl($0) }
    }
    /// Control remains leased after dispatch. Release or reclaim explicitly after reviewing the result;
    /// an untrusted shell completion never authorizes another command or returns control automatically.
    static func validateCommand(_ command: String) throws {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty, command.utf8.count <= 4096,
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else { throw AkittyError.core("Command must be one line of at most 4096 bytes without controls or invisible formatting characters.") }
    }
    public func execute(actor: String, command: String, approve: (AgentCommandRequest) async throws -> Bool) async throws -> (lease: UInt64, dispatch: AgentDispatch) {
        try Self.validateCommand(command)
        let lease = try session.acquireControl(actor: actor)
        var dispatchAttempted = false
        do {
            guard let shell = try session.shellState().shell, shell.ready else { throw AkittyError.core("An integrated shell prompt is required.") }
            let request = AgentCommandRequest(sessionID: session.id, actor: actor, command: command, cwd: shell.cwd)
            guard try await approve(request) else { try session.denyCommand(lease: lease); throw AkittyError.core("Command execution denied.") }
            let authorization = try session.authorizeCommand(lease: lease, command: command, expectedDirectory: request.cwd)
            dispatchAttempted = true
            return (lease, try dispatch(lease, authorization, command))
        } catch {
            let failure = error
            if dispatchAttempted {
                // Without a valid receipt we cannot assume no write happened. Preserve ownership for human review.
                throw AkittyError.core("Dispatch outcome is unknown; inspect the terminal and reclaim control. Do not retry automatically. \(failure.localizedDescription)")
            }
            // A concurrent human reclaim makes this lease stale; never reclaim a replacement controller.
            do { try release(lease) }
            catch let cleanupFailure {
                guard cleanupFailure.localizedDescription.contains("stale or invalid control lease") else {
                    throw AkittyError.core("\(failure.localizedDescription) Lease cleanup also failed: \(cleanupFailure.localizedDescription)")
                }
            }
            throw failure
        }
    }
    public static func confirm(_ request: AgentCommandRequest, in window: NSWindow) async -> Bool {
        guard window.attachedSheet == nil else { return false }
        let alert = approvalAlert(request)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            alert.window.makeFirstResponder(alert.buttons[1])
        }
    }
    static func approvalAlert(_ request: AgentCommandRequest, callerDescription: String? = nil) -> NSAlert {
        let alert = NSAlert(); alert.messageText = "Allow \(request.actor) to run this command?"
        alert.informativeText = "Terminal \(request.sessionID)\nDirectory reported by shell: \(request.cwd ?? "unknown")\n\n\(request.command.count <= 256 ? request.command : "Review the complete command in the scrollable text below.")"
        alert.addButton(withTitle: "Run Command"); alert.addButton(withTitle: "Deny")
        alert.buttons[0].keyEquivalent = ""
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        alert.window.initialFirstResponder = alert.buttons[1]
        alert.buttons[0].setAccessibilityHelp("Approve this exact command once in the displayed terminal and shell-reported directory.")
        alert.buttons[1].setAccessibilityHelp("Reject this command.")
        let note = NSTextField(wrappingLabelWithString: callerDescription ?? "The directory is reported by the shell and is not verified. Reclaiming control later does not stop a running command.")
        if request.command.count > 256 {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
            text.isEditable = false; text.isSelectable = true; text.isVerticallyResizable = true
            text.isHorizontallyResizable = false; text.textContainer?.widthTracksTextView = true
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.string = request.command
            text.setAccessibilityLabel("Complete exact command")
            let scroll = NSScrollView(frame: text.frame); scroll.hasVerticalScroller = true; scroll.documentView = text
            let stack = NSStackView(views: [scroll, note]); stack.orientation = .vertical; stack.alignment = .leading
            scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
            alert.accessoryView = stack
        } else { alert.accessoryView = note }
        return alert
    }
}
