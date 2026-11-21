import Foundation

public struct MuseMCPSettings: AgentMCPSettings {
    public let path: String
    public let executable: String
    private var entry: [String: Any] {
        ["type": "stdio", "command": executable, "args": ["mcp"], "required": false,
         "framing": "line_delimited_json", "tool_timeout_sec": 150]
    }
    private var hooks: ManagedHookGroups {
        ManagedHookGroups(managed: [("SessionStart", nil, 10), ("SessionEnd", nil, 10)],
                          command: AgentHookSettings.shellQuoted(executable) + " muse-hook", subcommand: "muse-hook")
    }

    public init(path: String, executable: String) {
        self.path = path; self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }
    private func load() throws -> [String: Any] {
        let object = try SettingsFile.load(path)
        if !object.isEmpty {
            guard let version = object["schema_version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else {
                throw AgentIPCError.failure("\(path) must contain \"schema_version\": 1 for Muse Code; it was left unchanged.")
            }
        }
        if let servers = object["mcpServers"], !(servers is [String: Any]) {
            throw AgentIPCError.failure("\(path): \"mcpServers\" is not an object; it was left unchanged.")
        }
        try hooks.validate(object, path: path)
        return object
    }
    private func serverState(in settings: [String: Any]) -> AgentHookSettings.State {
        let current = (settings["mcpServers"] as? [String: Any])?["akitty"]
        if MCPConfig.standardServer(current, executable: executable) {
            return NSDictionary(dictionary: current as? [String: Any] ?? [:]) == NSDictionary(dictionary: entry) ? .installed : .partial
        }
        return current == nil ? .notInstalled : .conflict
    }
    public func state() throws -> AgentHookSettings.State {
        let settings = try load()
        return MCPConfig.combined(serverState(in: settings), hooks.state(in: settings, executable: executable))
    }
    public func install() throws {
        var settings = try load()
        guard serverState(in: settings) != .conflict else {
            throw AgentIPCError.failure("\(path) already has an MCP server named \"akitty\" that AkiTTY did not add; it was left unchanged.")
        }
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers["akitty"] = entry
        settings["mcpServers"] = servers
        settings["schema_version"] = 1
        try SettingsFile.save(hooks.installing(into: settings, executable: executable), to: path)
    }
    public func uninstall() throws {
        let original = try load()
        var settings = original
        if var servers = settings["mcpServers"] as? [String: Any], MCPConfig.standardServer(servers["akitty"], executable: executable) {
            servers.removeValue(forKey: "akitty")
            settings["mcpServers"] = servers.isEmpty ? nil : servers
        }
        let cleaned = hooks.removingManaged(from: settings, executable: executable)
        if NSDictionary(dictionary: cleaned) != NSDictionary(dictionary: original) { try SettingsFile.save(cleaned, to: path) }
    }
}
