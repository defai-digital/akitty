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
        try JSONDecoder().decode(AgentDispatch.self, from: call("command_execute", ["lease":lease,"authorization":authorization,"command":command]))
    }
    /// Bounded, session-local audit. A host needing durable records must persist every page and detect eviction.
    public func controlAudit(after: UInt64 = 0) throws -> Data { try call("control_audit", ["after":after]) }
}

/// Host policy and PTY authority remain separate from program status and terminal text.
@MainActor public final class AgentCommandHost {
    private let session: TerminalSession
    public init(session: TerminalSession) { self.session = session }
    /// Control remains leased after dispatch. Release or reclaim explicitly after reviewing the result;
    /// an untrusted shell completion never authorizes another command or returns control automatically.
    public func execute(actor: String, command: String, approve: (AgentCommandRequest) async throws -> Bool) async throws -> (lease: UInt64, dispatch: AgentDispatch) {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty, command.utf8.count <= 4096,
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AkittyError.core("Command must be one line of at most 4096 bytes without controls.") }
        let lease = try session.acquireControl(actor: actor)
        do {
            guard let snapshot = try session.snapshot(), let shell = snapshot.shell, shell.ready else { throw AkittyError.core("An integrated shell prompt is required.") }
            let request = AgentCommandRequest(sessionID: session.id, actor: actor, command: command, cwd: shell.cwd)
            guard try await approve(request) else { try session.denyCommand(lease: lease); throw AkittyError.core("Command execution denied.") }
            let authorization = try session.authorizeCommand(lease: lease, command: command, expectedDirectory: request.cwd)
            return (lease, try session.executeCommand(lease: lease, authorization: authorization, command: command))
        } catch {
            // A concurrent human reclaim makes this lease stale; never reclaim a replacement controller.
            do { try session.releaseControl(lease) }
            catch { if !error.localizedDescription.contains("stale or invalid control lease") { throw error } }
            throw error
        }
    }
    public static func confirm(_ request: AgentCommandRequest, in window: NSWindow) async -> Bool {
        guard window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = "Allow \(request.actor) to run this command?"
        alert.informativeText = "Terminal \(request.sessionID)\nDirectory reported by shell: \(request.cwd ?? "unknown")\n\n\(request.command)"
        alert.addButton(withTitle: "Run Command"); alert.addButton(withTitle: "Deny")
        return await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) } }
    }
}
