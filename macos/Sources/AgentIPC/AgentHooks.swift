import Foundation

/// The coding agents whose official hooks AkiTTY answers. Claude Code and Codex share one hook contract:
/// a `PermissionRequest` answered with `hookSpecificOutput.decision.behavior`, plus `SessionStart`/`SessionEnd`.
public enum HookAgent: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    public var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    /// The `akitty-agent` subcommand the agent runs as its hook.
    public var subcommand: String { self == .claudeCode ? "claude-hook" : "codex-hook" }
    /// The `akitty-agent` subcommand that installs, removes or reports the hooks.
    public var settingsCommand: String { subcommand + "s" }
    /// Claude Code's user settings, or Codex's user hooks file (in `$CODEX_HOME`, default `~/.codex`).
    public var defaultSettingsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeCode: return home.appendingPathComponent(".claude/settings.json").path
        case .codex:
            // A relative CODEX_HOME is not used; `codexHomeWarning` says so.
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            return URL(fileURLWithPath: codexHome ?? home.appendingPathComponent(".codex").path).appendingPathComponent("hooks.json").path
        }
    }
    /// Explains where the Codex hooks file comes from when the environment may disagree with the user's shell.
    public var codexHomeWarning: String? {
        guard self == .codex else { return nil }
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"], !value.hasPrefix("/") {
            return "CODEX_HOME (\(value)) is not an absolute path, so ~/.codex/hooks.json is used."
        }
        return "If you set CODEX_HOME in your shell, run `akitty-agent codex-hooks install` from that shell instead: apps opened from the Finder do not see it."
    }
    /// Event, matcher and timeout (seconds) for each managed hook. The permission timeout exceeds AkiTTY's
    /// 120-second approval and 135-second socket deadlines, so the agent does not cancel a pending answer first.
    /// Codex allows SessionEnd at most 3 seconds.
    var managed: [(event: String, matcher: String?, timeout: Int)] {
        [("PermissionRequest", "Bash", 150), ("SessionStart", nil, 10), ("SessionEnd", nil, self == .codex ? 3 : 10)]
    }
}

/// Hook adapter: forwards a Bash permission prompt to AkiTTY and maps the human's answer back.
/// Anything AkiTTY cannot answer produces no output, so the agent keeps its own prompt.
public enum AgentHook {
    public static let inputLimit = 1 << 20
    static let reportTimeout: TimeInterval = 1.5
    /// Whether the sheet can show everything the agent asks for. Codex also sends network approvals as Bash
    /// (described as `network-access <host>`) and may add escalation fields; those stay with Codex's own prompt.
    static func isDescribable(_ input: [String: Any], agent: HookAgent) -> Bool {
        guard agent == .codex else { return true }
        guard Set(input.keys).isSubset(of: ["command", "description"]) else { return false }
        let description = (input["description"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return !description.hasPrefix("network-access") && !description.hasPrefix("network access")
    }

    /// The hook's stdout for one event: nil means "no decision" (print nothing, exit 0).
    public static func respond(to input: Data, agent: HookAgent = .claudeCode, path: String = LocalSocket.defaultPath,
                               send: (Data, String, TimeInterval) throws -> Data = { try LocalSocket.request($0, path: $1, timeout: $2) }) -> Data? {
        guard input.count <= inputLimit,
              let event = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let name = event["hook_event_name"] as? String else { return nil }
        switch name {
        case "PermissionRequest":
            guard event["tool_name"] as? String == "Bash",
                  let tool = event["tool_input"] as? [String: Any], let command = tool["command"] as? String,
                  command.utf8.count <= 4096, isDescribable(tool, agent: agent) else { return nil }
            var request: [String: Any] = ["version": 1, "op": "decide", "agent": agent.rawValue, "tool": "Bash", "command": command]
            if let cwd = event["cwd"] as? String, cwd.utf8.count <= 4096 { request["cwd"] = cwd }
            if let reason = tool["description"] as? String { request["reason"] = String(reason.prefix(300)) }
            guard let payload = try? JSONSerialization.data(withJSONObject: request), payload.count <= LocalSocket.frameLimit,
                  let reply = try? send(payload, path, 135),
                  let envelope = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  envelope["ok"] as? Bool == true, let data = envelope["data"] as? [String: Any],
                  let decision = data["decision"] as? String, decision == "allow" || decision == "deny" else { return nil }
            var answer: [String: Any] = ["behavior": decision]
            if decision == "deny" { answer["message"] = "Denied by the user in AkiTTY." }
            return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": answer]], options: [.sortedKeys])
        case "SessionStart", "SessionEnd":
            guard let session = event["session_id"] as? String else { return nil }
            let request: [String: Any] = ["version": 1, "op": "report", "agent": agent.rawValue,
                                          "event": name == "SessionStart" ? "session_start" : "session_end", "session_id": session]
            // Reports must finish well inside the agent's limit for these hooks (Codex kills SessionEnd after 3 s).
            if let payload = try? JSONSerialization.data(withJSONObject: request) { _ = try? send(payload, path, reportTimeout) }
            return nil
        default: return nil
        }
    }
}

/// Adds or removes AkiTTY's hooks in an agent's settings or hooks file, leaving every other setting and hook in
/// place. AkiTTY's entries are recognized by their command, so enabling twice keeps one copy.
public struct AgentHookSettings {
    public static let marker = "akitty-agent"
    public let agent: HookAgent
    public let path: String
    public let executable: String
    var managed: [(event: String, matcher: String?, timeout: Int)] { agent.managed }
    /// The executable is canonicalized, so the app menu and the CLI write and recognize the same command.
    public init(agent: HookAgent = .claudeCode, path: String? = nil, executable: String) {
        self.agent = agent; self.path = path ?? agent.defaultSettingsPath
        self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }

    /// Single-quoted for the shell the agent runs hooks in; an embedded quote is closed, escaped and reopened.
    public var command: String { Self.shellQuoted(executable) + " " + agent.subcommand }
    static func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// AkiTTY's entries: this copy's exact command, or the same form for the companion inside another AkiTTY app
    /// bundle (an older or moved install). A user's own tool, even one named akitty-agent elsewhere, is never touched.
    func isManaged(_ hook: [String: Any]) -> Bool {
        guard let value = hook["command"] as? String else { return false }
        if value == command { return true }
        return value.hasPrefix("'/") && value.hasSuffix(".app/Contents/MacOS/\(Self.marker)' \(agent.subcommand)")
    }
    /// `conflict`: an entry with AkiTTY's name that AkiTTY did not add (AX Code's MCP server); it is left alone.
    public enum State: Equatable { case notInstalled, installed, partial, conflict }

    func load() throws -> [String: Any] {
        let object = try SettingsFile.load(path)
        // Refuse shapes AkiTTY would otherwise have to overwrite, rather than lose a hand-written entry.
        if let hooks = object["hooks"] {
            guard let hooks = hooks as? [String: Any] else { throw AgentIPCError.failure("\(path): \"hooks\" is not an object; it was left unchanged.") }
            for entry in managed where hooks[entry.event] != nil && !(hooks[entry.event] is [[String: Any]]) {
                throw AgentIPCError.failure("\(path): hooks.\(entry.event) is not a list of hook groups; it was left unchanged.")
            }
        }
        return object
    }
    public func state() throws -> State {
        let hooks = try load()["hooks"] as? [String: Any] ?? [:]
        let found = managed.filter { entry in
            (hooks[entry.event] as? [[String: Any]] ?? []).contains { group in
                let matches = entry.matcher.map { group["matcher"] as? String == $0 } ?? (group["matcher"] == nil)
                return matches && (group["hooks"] as? [[String: Any]] ?? []).contains {
                    $0["command"] as? String == command && $0["type"] as? String == "command" && $0["timeout"] as? Int == entry.timeout
                }
            }
        }.count
        let anyManaged = hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { ($0["hooks"] as? [[String: Any]] ?? []).contains(where: isManaged) }
        }
        return found == managed.count ? .installed : (found > 0 || anyManaged) ? .partial : .notInstalled
    }
    /// Settings with every AkiTTY entry removed; groups and events left empty by that are dropped.
    func removingManaged(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = handlers.filter { !isManaged($0) }
                if remaining.count == handlers.count { return group }
                if remaining.isEmpty { return nil }
                var group = group; group["hooks"] = remaining; return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }
    func installing(into settings: [String: Any]) -> [String: Any] {
        var settings = removingManaged(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for entry in managed {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": entry.timeout]]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            hooks[entry.event] = (hooks[entry.event] as? [[String: Any]] ?? []) + [group]
        }
        settings["hooks"] = hooks
        return settings
    }
    func save(_ settings: [String: Any]) throws { try SettingsFile.save(settings, to: path) }
    public func install() throws { try save(installing(into: try load())) }
    public func uninstall() throws {
        let settings = try load()
        let cleaned = removingManaged(from: settings)
        if NSDictionary(dictionary: cleaned) != NSDictionary(dictionary: settings) { try save(cleaned) }
    }
}

/// Writes an agent's JSON settings file the way a person would want it kept.
enum SettingsFile {
    /// The file a write lands in. A symlink to a missing file is refused rather than replaced by a plain file.
    static func resolved(_ path: String) throws -> URL {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil, !FileManager.default.fileExists(atPath: path) {
            throw AgentIPCError.failure("\(path) is a symbolic link to a missing file; it was left unchanged.")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    /// Reads a JSON object, or an empty one when the file is missing or empty.
    static func load(_ path: String) throws -> [String: Any] {
        _ = try resolved(path)
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentIPCError.failure("\(path) is not a JSON object; it was left unchanged.")
        }
        return object
    }
    /// Read, change and write are not locked against another program editing the file at the same moment.
    static func save(_ settings: [String: Any], to path: String) throws {
        // Write through a symlink (a dotfiles checkout, for example) instead of replacing it with a plain file.
        let target = try resolved(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var info = stat()
        let existing = stat(target.path, &info) == 0
        // Keep the user's original contents once, beside the path they use, before AkiTTY first rewrites it.
        let backup = URL(fileURLWithPath: path + ".akitty-backup")
        if existing, !FileManager.default.fileExists(atPath: backup.path) {
            try Data(contentsOf: target).write(to: backup)
            _ = chmod(backup.path, info.st_mode & 0o777)
        }
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        try data.write(to: target, options: .atomic)
        // An atomic write creates a new file; keep the original's permissions (new files are private to the user).
        _ = chmod(target.path, existing ? info.st_mode & 0o777 : 0o600)
    }
}
