import Foundation

public struct AGYMCPSettings: AgentMCPSettings {
    public let path: String
    public let hooksPath: String
    public let executable: String
    private var entry: [String: Any] { ["command": executable, "args": ["mcp"], "disabled": false] }
    private var hookEntry: [String: Any] {
        ["SessionStart": [["hooks": [["type": "command", "command": AgentHookSettings.shellQuoted(executable) + " agy-hook", "timeout": 10]]]]]
    }

    public init(path: String, hooksPath: String, executable: String) {
        self.path = path; self.hooksPath = hooksPath
        self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }
    private func loadServers() throws -> [String: Any] {
        let object = try SettingsFile.load(path)
        if let servers = object["mcpServers"], !(servers is [String: Any]) {
            throw AgentIPCError.failure("\(path): \"mcpServers\" is not an object; it was left unchanged.")
        }
        return object
    }
    private func serverState(in settings: [String: Any]) -> AgentHookSettings.State {
        let current = (settings["mcpServers"] as? [String: Any])?["akitty"]
        if MCPConfig.standardServer(current, executable: executable) {
            return NSDictionary(dictionary: current as? [String: Any] ?? [:]) == NSDictionary(dictionary: entry) ? .installed : .partial
        }
        return current == nil ? .notInstalled : .conflict
    }
    private func managedHook(_ value: Any?) -> Bool {
        guard let entry = value as? [String: Any], let groups = entry["SessionStart"] as? [[String: Any]] else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { handler in
                guard let command = handler["command"] as? String else { return false }
                return command == AgentHookSettings.shellQuoted(executable) + " agy-hook" ||
                    command.hasPrefix("'/") && command.hasSuffix(".app/Contents/MacOS/akitty-agent' agy-hook")
            }
        }
    }
    private func hookState() throws -> AgentHookSettings.State {
        let settings = try SettingsFile.load(hooksPath)
        let current = settings["akitty"]
        if managedHook(current) {
            return NSDictionary(dictionary: current as? [String: Any] ?? [:]) == NSDictionary(dictionary: hookEntry) ? .installed : .partial
        }
        return current == nil ? .notInstalled : .conflict
    }
    public func state() throws -> AgentHookSettings.State {
        MCPConfig.combined(serverState(in: try loadServers()), try hookState())
    }
    public func install() throws {
        var settings = try loadServers()
        guard serverState(in: settings) != .conflict else {
            throw AgentIPCError.failure("\(path) already has an MCP server named \"akitty\" that AkiTTY did not add; it was left unchanged.")
        }
        var hooks = try SettingsFile.load(hooksPath)
        guard try hookState() != .conflict else {
            throw AgentIPCError.failure("\(hooksPath) already has an \"akitty\" hook that AkiTTY did not add; it was left unchanged.")
        }
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers["akitty"] = entry; settings["mcpServers"] = servers
        hooks["akitty"] = hookEntry
        try SettingsFile.save(hooks, to: hooksPath)
        try SettingsFile.save(settings, to: path)
    }
    public func uninstall() throws {
        var settings = try loadServers()
        if var servers = settings["mcpServers"] as? [String: Any], MCPConfig.standardServer(servers["akitty"], executable: executable) {
            servers.removeValue(forKey: "akitty")
            settings["mcpServers"] = servers.isEmpty ? nil : servers
            try SettingsFile.save(settings, to: path)
        }
        var hooks = try SettingsFile.load(hooksPath)
        if managedHook(hooks["akitty"]) {
            hooks.removeValue(forKey: "akitty")
            try SettingsFile.save(hooks, to: hooksPath)
        }
    }
}
