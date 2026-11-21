import Foundation

/// A client-specific MCP and lifecycle integration installed through one Settings row or companion subcommand.
public protocol AgentMCPSettings {
    var path: String { get }
    func state() throws -> AgentHookSettings.State
    func install() throws
    func uninstall() throws
}

public enum MCPIntegrationAgent: String, CaseIterable, Sendable {
    case axCode = "ax-code", grok, muse, kimi, agy

    public var displayName: String {
        switch self {
        case .axCode: return "AX Code"
        case .grok: return "Grok"
        case .muse: return "Muse Code"
        case .kimi: return "Kimi Code"
        case .agy: return "AGY"
        }
    }
    public var settingsCommand: String { rawValue + "-mcp" }
    public var usesPlugin: Bool { self == .axCode }

    public var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .axCode: return AXCodeMCPSettings.defaultPath
        case .grok:
            let base = ProcessInfo.processInfo.environment["GROK_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            return URL(fileURLWithPath: base ?? home.appendingPathComponent(".grok").path).appendingPathComponent("config.toml").path
        case .muse:
            let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            return URL(fileURLWithPath: base ?? home.appendingPathComponent(".config").path).appendingPathComponent("muse/settings.json").path
        case .kimi:
            let base = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            return URL(fileURLWithPath: base ?? home.appendingPathComponent(".kimi-code").path).appendingPathComponent("mcp.json").path
        case .agy: return home.appendingPathComponent(".gemini/config/mcp_config.json").path
        }
    }

    public var configHomeWarning: String {
        switch self {
        case .axCode: return AXCodeMCPSettings.configHomeWarning
        case .grok: return "If you set GROK_HOME in your shell, run `akitty-agent grok-mcp install` from that shell instead: apps opened from the Finder do not see it."
        case .muse: return "If you set XDG_CONFIG_HOME in your shell, run `akitty-agent muse-mcp install` from that shell instead: apps opened from the Finder do not see it."
        case .kimi: return "If you set KIMI_CODE_HOME in your shell, run `akitty-agent kimi-mcp install` from that shell instead: apps opened from the Finder do not see it."
        case .agy: return "AGY reads the MCP server and lifecycle hook from ~/.gemini/config. Restart AGY after changing them."
        }
    }

    public var instructions: String {
        switch self {
        case .axCode:
            return "AX Code asks AkiTTY to run a shell command in a pane through the akitty request_command tool; every command waits for your approval. A small plugin reports the conversation in each pane so AkiTTY can offer ax-code --session after a restart. AkiTTY writes only ax-code.json and that plugin, never your commented ax-code.jsonc. Restart AX Code to load a change."
        case .grok:
            return "Grok can request commands through AkiTTY's MCP server and reports SessionStart and SessionEnd through ~/.grok/hooks/akitty.json. AkiTTY can offer grok --resume after a restart. Grok's own permission prompts stay in Grok. Restart Grok to load a change."
        case .muse:
            return "Muse Code can request commands through AkiTTY's MCP server and reports sessions through its settings hooks. AkiTTY can offer muse resume after a restart. Muse Code's own permission prompts stay in Muse Code. Restart Muse Code to load a change."
        case .kimi:
            return "Kimi Code can request commands through AkiTTY's MCP server and reports sessions through managed config.toml hooks. AkiTTY can offer kimi --session after a restart. Kimi Code's PermissionRequest hook is observation-only, so its own prompts stay in Kimi Code. Start a new session to load a change."
        case .agy:
            return "AGY can request commands through AkiTTY's MCP server and reports SessionStart through ~/.gemini/config/hooks.json. AkiTTY can offer agy --conversation after a restart. AGY documents no SessionEnd hook, and its own prompts stay in AGY. Restart AGY to load a change."
        }
    }

    public func settings(path: String? = nil, hooksPath: String? = nil, executable: String) -> any AgentMCPSettings {
        let configPath = path ?? defaultPath
        switch self {
        case .axCode: return AXCodeMCPSettings(path: configPath, executable: executable)
        case .grok:
            let hooks = hooksPath ?? URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("hooks/akitty.json").path
            return GrokMCPSettings(path: configPath, hooksPath: hooks, executable: executable)
        case .muse: return MuseMCPSettings(path: configPath, executable: executable)
        case .kimi:
            let hooks = hooksPath ?? URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("config.toml").path
            return KimiMCPSettings(path: configPath, hooksPath: hooks, executable: executable)
        case .agy:
            let hooks = hooksPath ?? URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("hooks.json").path
            return AGYMCPSettings(path: configPath, hooksPath: hooks, executable: executable)
        }
    }
}

enum MCPConfig {
    static func companionPath(_ value: String, executable: String) -> Bool {
        value == executable || (value.hasPrefix("/") && value.hasSuffix(".app/Contents/MacOS/akitty-agent"))
    }

    static func standardServer(_ value: Any?, executable: String) -> Bool {
        guard let server = value as? [String: Any], let command = server["command"] as? String,
              let args = server["args"] as? [String], args == ["mcp"] else { return false }
        return companionPath(command, executable: executable)
    }

    static func combined(_ first: AgentHookSettings.State, _ second: AgentHookSettings.State) -> AgentHookSettings.State {
        if first == .conflict || second == .conflict { return .conflict }
        if first == second { return first }
        return .partial
    }

    static func tomlString(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else {
            throw AgentIPCError.failure("A configuration path contains a control or invisible formatting character.")
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum TextSettingsFile {
    static func load(_ path: String) throws -> String {
        _ = try SettingsFile.resolved(path)
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    static func save(_ text: String, to path: String) throws {
        let target = try SettingsFile.resolved(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var info = stat()
        let existing = stat(target.path, &info) == 0
        let backup = URL(fileURLWithPath: path + ".akitty-backup")
        if existing, !FileManager.default.fileExists(atPath: backup.path) {
            try Data(contentsOf: target).write(to: backup)
            _ = chmod(backup.path, info.st_mode & 0o777)
        }
        try Data(text.utf8).write(to: target, options: .atomic)
        _ = chmod(target.path, existing ? info.st_mode & 0o777 : 0o600)
    }
}

/// A replaceable TOML fragment that leaves every byte outside its markers untouched.
struct ManagedTextBlock {
    let name: String
    var begin: String { "# >>> AkiTTY (\(name)) >>>" }
    var end: String { "# <<< AkiTTY (\(name)) <<<" }

    func body(in text: String) throws -> String? {
        let first = text.range(of: begin), last = text.range(of: end)
        switch (first, last) {
        case (nil, nil): return nil
        case let (start?, end?) where start.lowerBound < end.lowerBound:
            guard text.range(of: begin, range: start.upperBound..<text.endIndex) == nil,
                  text.range(of: self.end, range: end.upperBound..<text.endIndex) == nil else {
                throw AgentIPCError.failure("Duplicate AkiTTY managed blocks were found; the configuration was left unchanged.")
            }
            return String(text[start.lowerBound..<end.upperBound])
        default: throw AgentIPCError.failure("An incomplete AkiTTY managed block was found; the configuration was left unchanged.")
        }
    }

    func installing(_ body: String, into text: String) throws -> String {
        let content = begin + "\n" + body + "\n" + end
        if let existing = try self.body(in: text) {
            guard let range = text.range(of: existing) else { return text }
            return text.replacingCharacters(in: range, with: content)
        }
        var result = text
        if !result.isEmpty && !result.hasSuffix("\n") { result.append("\n") }
        if !result.isEmpty { result.append("\n") }
        return result + content + "\n"
    }

    func removing(from text: String) throws -> String {
        guard let existing = try body(in: text), let range = text.range(of: existing) else { return text }
        var result = text
        result.removeSubrange(range)
        return result
    }

    func conflictsWithGrokServer(in text: String) throws -> Bool {
        var unmanaged = text
        if let managed = try body(in: text), let range = text.range(of: managed) { unmanaged.removeSubrange(range) }
        var section = ""
        for line in unmanaged.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") { continue }
            let normalized = trimmed.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            if normalized.hasPrefix("[") {
                let header = normalized.components(separatedBy: "#").first ?? normalized
                section = header
                if header == "[[mcp_servers]]" || header == "[mcp_servers.akitty]" || header.hasPrefix("[mcp_servers.akitty.") ||
                    header == "[[mcp_servers.akitty]]" || header.hasPrefix("[[mcp_servers.akitty.") { return true }
                continue
            }
            if normalized.hasPrefix("mcp_servers.akitty=") || normalized.hasPrefix("mcp_servers.akitty.") ||
                section == "[mcp_servers]" && (normalized.hasPrefix("akitty=") || normalized.hasPrefix("akitty.")) ||
                section.isEmpty && normalized.hasPrefix("mcp_servers=") { return true }
        }
        return false
    }
}
