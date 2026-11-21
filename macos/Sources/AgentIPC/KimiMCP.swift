import Foundation

public struct KimiMCPSettings: AgentMCPSettings {
    public let path: String
    public let hooksPath: String
    public let executable: String
    private var marker: ManagedTextBlock { ManagedTextBlock(name: "kimi") }
    private var entry: [String: Any] { ["command": executable, "args": ["mcp"], "toolTimeoutMs": 150_000] }

    public init(path: String, hooksPath: String, executable: String) {
        self.path = path; self.hooksPath = hooksPath
        self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }
    private var body: String {
        get throws {
            let command = try MCPConfig.tomlString(AgentHookSettings.shellQuoted(executable) + " kimi-hook")
            return "[[hooks]]\nevent = \"SessionStart\"\ncommand = \(command)\ntimeout = 10\n\n[[hooks]]\nevent = \"SessionEnd\"\ncommand = \(command)\ntimeout = 10"
        }
    }
    private var content: String { get throws { marker.begin + "\n" + (try body) + "\n" + marker.end } }

    private func load() throws -> [String: Any] {
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
    private func hookState() throws -> AgentHookSettings.State {
        let text = try TextSettingsFile.load(hooksPath)
        guard let current = try marker.body(in: text) else { return .notInstalled }
        return current == (try content) ? .installed : .partial
    }
    public func state() throws -> AgentHookSettings.State {
        MCPConfig.combined(serverState(in: try load()), try hookState())
    }
    public func install() throws {
        var settings = try load()
        guard serverState(in: settings) != .conflict else {
            throw AgentIPCError.failure("\(path) already has an MCP server named \"akitty\" that AkiTTY did not add; it was left unchanged.")
        }
        let text = try TextSettingsFile.load(hooksPath)
        let updatedHooks = try marker.installing(try body, into: text)
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers["akitty"] = entry; settings["mcpServers"] = servers
        try SettingsFile.save(settings, to: path)
        try TextSettingsFile.save(updatedHooks, to: hooksPath)
    }
    public func uninstall() throws {
        var settings = try load()
        let text = try TextSettingsFile.load(hooksPath), cleaned = try marker.removing(from: text)
        if var servers = settings["mcpServers"] as? [String: Any], MCPConfig.standardServer(servers["akitty"], executable: executable) {
            servers.removeValue(forKey: "akitty")
            settings["mcpServers"] = servers.isEmpty ? nil : servers
            try SettingsFile.save(settings, to: path)
        }
        if cleaned != text { try TextSettingsFile.save(cleaned, to: hooksPath) }
    }
}
