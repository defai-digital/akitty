import Foundation

/// Agents whose lifecycle hooks report conversations but do not answer permission prompts through AkiTTY.
public enum SessionHookAgent: String, CaseIterable, Sendable {
    case grok, muse, kimi, agy

    public var displayName: String {
        switch self {
        case .grok: return "Grok"
        case .muse: return "Muse Code"
        case .kimi: return "Kimi Code"
        case .agy: return "AGY"
        }
    }
    public var subcommand: String { rawValue + "-hook" }
}

/// Maps client-specific lifecycle payloads to AkiTTY's untrusted conversation report.
/// AGY documents SessionStart only; its Stop event is deliberately not treated as SessionEnd.
public enum SessionHook {
    public static let inputLimit = 1 << 20
    static let reportTimeout: TimeInterval = 1.5

    public static func respond(to input: Data, agent: SessionHookAgent, path: String = LocalSocket.defaultPath,
                               send: (Data, String, TimeInterval) throws -> Data = { try LocalSocket.request($0, path: $1, timeout: $2) }) -> Data? {
        guard input.count <= inputLimit,
              let event = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        let session: String
        let reportEvent: String
        if agent == .agy {
            // AGY's SessionStart hook has conversationId but no hook_event_name. Do not guess for other payloads.
            func absent(_ key: String) -> Bool { event[key] == nil || event[key] is NSNull }
            guard let id = event["conversationId"] as? String,
                  absent("toolCall"), absent("terminationReason"), absent("invocationNum"), absent("stepIdx"), absent("executionNum") else { return nil }
            session = id; reportEvent = "session_start"
        } else {
            let snakeID = event["session_id"] as? String, camelID = event["sessionId"] as? String
            guard let name = event["hook_event_name"] as? String, name == "SessionStart" || name == "SessionEnd",
                  let id = snakeID ?? camelID, snakeID == nil || camelID == nil || snakeID == camelID else { return nil }
            session = id; reportEvent = name == "SessionStart" ? "session_start" : "session_end"
        }
        let request: [String: Any] = ["version": 1, "op": "report", "agent": agent.rawValue,
                                      "event": reportEvent, "session_id": session]
        if let payload = try? JSONSerialization.data(withJSONObject: request) { _ = try? send(payload, path, reportTimeout) }
        return nil
    }
}

/// Shared matcher-group editing for clients whose hooks use the Claude-compatible JSON shape.
struct ManagedHookGroups {
    let managed: [(event: String, matcher: String?, timeout: Int)]
    let command: String
    let subcommand: String

    func validate(_ settings: [String: Any], path: String) throws {
        if let hooks = settings["hooks"] {
            guard let hooks = hooks as? [String: Any] else { throw AgentIPCError.failure("\(path): \"hooks\" is not an object; it was left unchanged.") }
            for entry in managed where hooks[entry.event] != nil && !(hooks[entry.event] is [[String: Any]]) {
                throw AgentIPCError.failure("\(path): hooks.\(entry.event) is not a list of hook groups; it was left unchanged.")
            }
        }
    }

    func isManaged(_ hook: [String: Any], executable: String) -> Bool {
        guard let value = hook["command"] as? String else { return false }
        if value == command { return true }
        return value.hasPrefix("'/") && value.hasSuffix(".app/Contents/MacOS/akitty-agent' \(subcommand)")
    }

    func state(in settings: [String: Any], executable: String) -> AgentHookSettings.State {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let found = managed.filter { entry in
            (hooks[entry.event] as? [[String: Any]] ?? []).contains { group in
                let matches = entry.matcher.map { group["matcher"] as? String == $0 } ?? (group["matcher"] == nil)
                return matches && (group["hooks"] as? [[String: Any]] ?? []).contains {
                    $0["command"] as? String == command && $0["type"] as? String == "command" && $0["timeout"] as? Int == entry.timeout
                }
            }
        }.count
        let anyManaged = hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { ($0["hooks"] as? [[String: Any]] ?? []).contains(where: { isManaged($0, executable: executable) }) }
        }
        return found == managed.count ? .installed : (found > 0 || anyManaged) ? .partial : .notInstalled
    }

    func removingManaged(from settings: [String: Any], executable: String) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = handlers.filter { !isManaged($0, executable: executable) }
                if remaining.count == handlers.count { return group }
                if remaining.isEmpty { return nil }
                var group = group; group["hooks"] = remaining; return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    func installing(into settings: [String: Any], executable: String) -> [String: Any] {
        var settings = removingManaged(from: settings, executable: executable)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for entry in managed {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": entry.timeout]]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            hooks[entry.event] = (hooks[entry.event] as? [[String: Any]] ?? []) + [group]
        }
        settings["hooks"] = hooks
        return settings
    }
}

/// Grok has a dedicated global hook directory, avoiding its Claude-compatible discovery path.
public struct GrokHookSettings {
    public let agent: SessionHookAgent
    public let path: String
    public let executable: String
    var managed: ManagedHookGroups {
        ManagedHookGroups(managed: [("SessionStart", nil, 10), ("SessionEnd", nil, 10)],
                          command: AgentHookSettings.shellQuoted(executable) + " " + agent.subcommand, subcommand: agent.subcommand)
    }
    public init(agent: SessionHookAgent = .grok, path: String, executable: String) {
        self.agent = agent; self.path = path
        self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }
    func load() throws -> [String: Any] {
        let object = try SettingsFile.load(path)
        try managed.validate(object, path: path)
        return object
    }
    public func state() throws -> AgentHookSettings.State { managed.state(in: try load(), executable: executable) }
    public func install() throws { try SettingsFile.save(managed.installing(into: load(), executable: executable), to: path) }
    public func uninstall() throws {
        let settings = try load(), cleaned = managed.removingManaged(from: settings, executable: executable)
        if NSDictionary(dictionary: cleaned) != NSDictionary(dictionary: settings) { try SettingsFile.save(cleaned, to: path) }
    }
}
