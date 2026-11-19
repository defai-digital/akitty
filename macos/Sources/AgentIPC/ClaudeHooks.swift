import Foundation

/// Claude Code hook adapter: forwards a Bash permission prompt to AkiTTY and maps the human's answer back.
/// Anything AkiTTY cannot answer produces no output, so Claude Code keeps its own prompt.
public enum ClaudeHook {
    public static let inputLimit = 1 << 20

    /// The hook's stdout for one event: nil means "no decision" (print nothing, exit 0).
    public static func respond(to input: Data, path: String = LocalSocket.defaultPath,
                               send: (Data, String) throws -> Data = { try LocalSocket.request($0, path: $1) }) -> Data? {
        guard input.count <= inputLimit,
              let event = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let name = event["hook_event_name"] as? String else { return nil }
        switch name {
        case "PermissionRequest":
            guard event["tool_name"] as? String == "Bash",
                  let tool = event["tool_input"] as? [String: Any], let command = tool["command"] as? String,
                  command.utf8.count <= 4096 else { return nil }
            var request: [String: Any] = ["version": 1, "op": "decide", "agent": "claude-code", "tool": "Bash", "command": command]
            if let cwd = event["cwd"] as? String, cwd.utf8.count <= 4096 { request["cwd"] = cwd }
            if let reason = tool["description"] as? String { request["reason"] = String(reason.prefix(300)) }
            guard let payload = try? JSONSerialization.data(withJSONObject: request), payload.count <= LocalSocket.frameLimit,
                  let reply = try? send(payload, path),
                  let envelope = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  envelope["ok"] as? Bool == true, let data = envelope["data"] as? [String: Any],
                  let decision = data["decision"] as? String, decision == "allow" || decision == "deny" else { return nil }
            var answer: [String: Any] = ["behavior": decision]
            if decision == "deny" { answer["message"] = "Denied by the user in AkiTTY." }
            return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": answer]], options: [.sortedKeys])
        case "SessionStart", "SessionEnd":
            guard let session = event["session_id"] as? String else { return nil }
            let request: [String: Any] = ["version": 1, "op": "report", "agent": "claude-code",
                                          "event": name == "SessionStart" ? "session_start" : "session_end", "session_id": session]
            if let payload = try? JSONSerialization.data(withJSONObject: request) { _ = try? send(payload, path) }
            return nil
        default: return nil
        }
    }
}

/// Adds or removes AkiTTY's Claude Code hooks in a settings file, leaving every other setting and hook in place.
/// AkiTTY's entries are recognized by their command, so enabling twice keeps one copy.
public struct ClaudeHookSettings {
    public static let marker = "akitty-agent"
    public static let subcommand = "claude-hook"
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path
    }
    /// Event, matcher and timeout for each managed hook. The permission timeout exceeds AkiTTY's 120-second approval
    /// and 135-second socket deadlines, so Claude Code does not cancel a pending answer first.
    static let managed: [(event: String, matcher: String?, timeout: Int)] = [
        ("PermissionRequest", "Bash", 150), ("SessionStart", nil, 10), ("SessionEnd", nil, 10)
    ]
    public let path: String
    public let executable: String
    /// The executable is canonicalized, so the app menu and the CLI write and recognize the same command.
    public init(path: String = defaultPath, executable: String) {
        self.path = path; self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }

    /// Single-quoted for the shell Claude Code runs hooks in; an embedded quote is closed, escaped and reopened.
    public var command: String { Self.shellQuoted(executable) + " " + Self.subcommand }
    static func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// AkiTTY's entries: this copy's exact command, or the same form for the companion inside another AkiTTY app
    /// bundle (an older or moved install). A user's own tool, even one named akitty-agent elsewhere, is never touched.
    func isManaged(_ hook: [String: Any]) -> Bool {
        guard let value = hook["command"] as? String else { return false }
        if value == command { return true }
        return value.hasPrefix("'/") && value.hasSuffix(".app/Contents/MacOS/\(Self.marker)' \(Self.subcommand)")
    }
    public enum State: Equatable { case notInstalled, installed, partial }

    func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentIPCError.failure("\(path) is not a JSON object; it was left unchanged.")
        }
        // Refuse shapes AkiTTY would otherwise have to overwrite, rather than lose a hand-written entry.
        if let hooks = object["hooks"] {
            guard let hooks = hooks as? [String: Any] else { throw AgentIPCError.failure("\(path): \"hooks\" is not an object; it was left unchanged.") }
            for entry in Self.managed where hooks[entry.event] != nil && !(hooks[entry.event] is [[String: Any]]) {
                throw AgentIPCError.failure("\(path): hooks.\(entry.event) is not a list of hook groups; it was left unchanged.")
            }
        }
        return object
    }
    public func state() throws -> State {
        let hooks = try load()["hooks"] as? [String: Any] ?? [:]
        let found = Self.managed.filter { entry in
            (hooks[entry.event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }.count
        let anyManaged = hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { ($0["hooks"] as? [[String: Any]] ?? []).contains(where: isManaged) }
        }
        return found == Self.managed.count ? .installed : (found > 0 || anyManaged) ? .partial : .notInstalled
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
        for entry in Self.managed {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": entry.timeout]]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            hooks[entry.event] = (hooks[entry.event] as? [[String: Any]] ?? []) + [group]
        }
        settings["hooks"] = hooks
        return settings
    }
    /// Read, change and write are not locked against another program editing the file at the same moment.
    func save(_ settings: [String: Any]) throws {
        // Write through a symlink (a dotfiles checkout, for example) instead of replacing it with a plain file.
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
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
    public func install() throws { try save(installing(into: try load())) }
    public func uninstall() throws {
        let settings = try load()
        let cleaned = removingManaged(from: settings)
        if NSDictionary(dictionary: cleaned) != NSDictionary(dictionary: settings) { try save(cleaned) }
    }
}
