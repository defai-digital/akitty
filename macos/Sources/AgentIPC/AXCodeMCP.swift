import Foundation

/// Adds or removes AkiTTY's MCP server in AX Code's global config. AX Code merges `ax-code.json` with the
/// commented `ax-code.jsonc` people edit by hand, so AkiTTY writes only the plain-JSON file and never touches the
/// commented one. AX Code then asks AkiTTY to run a command through the `request_command` tool, which waits for
/// approval.
public struct AXCodeMCPSettings {
    public static let serverName = "akitty"
    public let path: String
    public let executable: String

    /// `$XDG_CONFIG_HOME/ax-code/ax-code.json` when that is an absolute path, else `~/.config/ax-code/ax-code.json`.
    public static var defaultPath: String {
        let environment = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        let base = environment ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
        return URL(fileURLWithPath: base).appendingPathComponent("ax-code/ax-code.json").path
    }
    /// Explains that a Finder-launched app does not see an `XDG_CONFIG_HOME` set in the person's shell.
    public static var configHomeWarning: String {
        "If you set XDG_CONFIG_HOME in your shell, run `akitty-agent ax-code-mcp install` from that shell instead: apps opened from the Finder do not see it."
    }
    public init(path: String? = nil, executable: String) {
        self.path = path ?? Self.defaultPath
        self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }
    /// The server entry AkiTTY writes: AX Code starts `akitty-agent mcp` itself, inside the pane it runs in.
    public var entry: [String: Any] { ["type": "local", "command": [executable, "mcp"]] }
    /// AkiTTY's entry: this copy's exact entry, or the companion inside another AkiTTY app bundle running `mcp`.
    /// A person's own tool, even one named akitty-agent elsewhere, is never treated as AkiTTY's.
    func isManaged(_ value: Any?) -> Bool {
        guard let server = value as? [String: Any], server["type"] as? String == "local",
              let command = server["command"] as? [String], command.count == 2, command[1] == "mcp" else { return false }
        return command[0] == executable || (command[0].hasPrefix("/") && command[0].hasSuffix(".app/Contents/MacOS/akitty-agent"))
    }
    func load() throws -> [String: Any] {
        // ax-code.json linked to the commented ax-code.jsonc would rewrite the file AkiTTY promises to leave alone.
        if try SettingsFile.resolved(path).pathExtension.lowercased() == "jsonc" {
            throw AgentIPCError.failure("\(path) links to a commented .jsonc file, which AkiTTY does not rewrite; it was left unchanged.")
        }
        let object = try SettingsFile.load(path)
        if let servers = object["mcp"], !(servers is [String: Any]) {
            throw AgentIPCError.failure("\(path): \"mcp\" is not an object; it was left unchanged.")
        }
        return object
    }
    public func state() throws -> AgentHookSettings.State {
        let current = (try load()["mcp"] as? [String: Any])?[Self.serverName]
        guard isManaged(current) else { return current == nil ? .notInstalled : .conflict }
        return NSDictionary(dictionary: current as? [String: Any] ?? [:]) == NSDictionary(dictionary: entry) ? .installed : .partial
    }
    public func install() throws {
        var settings = try load()
        var servers = settings["mcp"] as? [String: Any] ?? [:]
        // Never replace a server of the same name that the person set up themselves.
        if let existing = servers[Self.serverName], !isManaged(existing) {
            throw AgentIPCError.failure("\(path) already has an MCP server named \"\(Self.serverName)\" that AkiTTY did not add; it was left unchanged.")
        }
        servers[Self.serverName] = entry
        settings["mcp"] = servers
        try SettingsFile.save(settings, to: path)
    }
    public func uninstall() throws {
        var settings = try load()
        guard var servers = settings["mcp"] as? [String: Any], isManaged(servers[Self.serverName]) else { return }
        servers.removeValue(forKey: Self.serverName)
        settings["mcp"] = servers.isEmpty ? nil : servers
        try SettingsFile.save(settings, to: path)
    }
}
