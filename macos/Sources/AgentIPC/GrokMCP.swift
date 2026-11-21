import Foundation

public struct GrokMCPSettings: AgentMCPSettings {
    public let path: String
    public let hooksPath: String
    public let executable: String
    private var hooks: GrokHookSettings { GrokHookSettings(path: hooksPath, executable: executable) }
    private var marker: ManagedTextBlock { ManagedTextBlock(name: "grok") }

    public init(path: String, hooksPath: String, executable: String) {
        self.path = path; self.hooksPath = hooksPath
        self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }
    private var body: String {
        get throws {
            let command = try MCPConfig.tomlString(executable)
            return "[mcp_servers.akitty]\ncommand = \(command)\nargs = [\"mcp\"]\ntool_timeout_sec = 150"
        }
    }
    private var content: String { get throws { marker.begin + "\n" + (try body) + "\n" + marker.end } }

    public func state() throws -> AgentHookSettings.State {
        let text = try TextSettingsFile.load(path)
        if try marker.conflictsWithGrokServer(in: text) { return .conflict }
        let server: AgentHookSettings.State
        if let current = try marker.body(in: text) {
            server = current == (try content) ? .installed : .partial
        } else { server = .notInstalled }
        return MCPConfig.combined(server, try hooks.state())
    }
    public func install() throws {
        let text = try TextSettingsFile.load(path)
        guard try !marker.conflictsWithGrokServer(in: text) else {
            throw AgentIPCError.failure("\(path) defines an MCP table that conflicts with AkiTTY's server; it was left unchanged.")
        }
        // Validate both files before changing either one, then leave an explicit partial state if the second write fails.
        let updated = try marker.installing(try body, into: text)
        try hooks.install()
        try TextSettingsFile.save(updated, to: path)
    }
    public func uninstall() throws {
        let text = try TextSettingsFile.load(path)
        let cleaned = try marker.removing(from: text)
        if cleaned != text { try TextSettingsFile.save(cleaned, to: path) }
        try hooks.uninstall()
    }
}
