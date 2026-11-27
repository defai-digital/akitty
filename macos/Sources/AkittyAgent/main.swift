import Foundation
import AgentIPC
import AkittyMCP
import Darwin

do {
    signal(SIGPIPE, SIG_IGN)
    var args = Array(CommandLine.arguments.dropFirst())
    var path = LocalSocket.defaultPath
    if args.count >= 2, args[0] == "--socket" { path = args[1]; args.removeFirst(2) }
    if args == ["mcp"] {
        try await AkittyMCPServer.run(path: path)
        exit(0)
    }
    if args.count == 1, let agent = HookAgent.allCases.first(where: { $0.subcommand == args[0] }) {
        // Never fail the agent: any error means no output, and the agent keeps its own prompt.
        let input = FileHandle.standardInput.readData(ofLength: AgentHook.inputLimit + 1)
        if let output = AgentHook.respond(to: input, agent: agent, path: path) {
            FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(0)
    }
    if args.count >= 2, let agent = HookAgent.allCases.first(where: { $0.settingsCommand == args[0] }) {
        let usage = "Usage: akitty-agent \(agent.settingsCommand) install|uninstall|status [--settings path]"
        var settingsPath = agent.defaultSettingsPath
        if args.count == 4, args[2] == "--settings" { settingsPath = args[3] } else if args.count != 2 { throw AgentIPCError.failure(usage) }
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let settings = AgentHookSettings(agent: agent, path: settingsPath, executable: executable)
        var reload = agent == .codex ? "Then trust them with /hooks in Codex; Codex skips new or changed hooks until they are trusted." : "Restart running Claude Code sessions to load them."
        if agent == .codex, let value = ProcessInfo.processInfo.environment["CODEX_HOME"], !value.hasPrefix("/"), let warning = agent.codexHomeWarning { reload += " " + warning }
        switch args[1] {
        case "install": try settings.install(); print("Installed AkiTTY hooks for \(agent.displayName) in \(settingsPath). \(reload)")
        case "uninstall": try settings.uninstall(); print("Removed AkiTTY hooks from \(settingsPath). Other hooks were left in place.")
        case "status": print("\(try settings.state()) (\(settingsPath))")
        default: throw AgentIPCError.failure(usage)
        }
        exit(0)
    }
    if args.count == 1, let agent = SessionHookAgent.allCases.first(where: { $0.subcommand == args[0] }) {
        // Reporting hooks are best-effort and never affect the client's own lifecycle or approval flow.
        let input = FileHandle.standardInput.readData(ofLength: SessionHook.inputLimit + 1)
        if let output = SessionHook.respond(to: input, agent: agent, path: path) {
            FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(0)
    }
    if args.count == 2, args[0] == "ax-code-reporter" {
        let request: [String: Any] = ["version": 1, "op": "reporter_begin", "reporter_id": args[1]]
        let reply = try LocalSocket.request(JSONSerialization.data(withJSONObject: request), path: path, timeout: 2)
        FileHandle.standardOutput.write(reply); exit(0)
    }
    if (args.count == 3 || args.count == 6) && args[0] == "ax-code-report" && ["start", "end"].contains(args[1]) {
        // Started by AkiTTY's AX Code plugin. Never fail AX Code: report briefly and always exit 0 quietly.
        var request: [String: Any] = ["version": 1, "op": "report", "agent": "ax-code",
                                      "event": args[1] == "start" ? "session_start" : "session_end", "session_id": args[2]]
        if args.count == 6 {
            request["reporter_id"] = args[3]; request["reporter_sequence"] = args[4]; request["reporter_started"] = args[5]
        }
        if let payload = try? JSONSerialization.data(withJSONObject: request), let reply = try? LocalSocket.request(payload, path: path, timeout: 1.5) {
            FileHandle.standardOutput.write(reply)
        }
        exit(0)
    }
    if args.count >= 2, let agent = MCPIntegrationAgent.allCases.first(where: { $0.settingsCommand == args[0] }) {
        let usage = "Usage: akitty-agent \(agent.settingsCommand) install|uninstall|status [--config path] [--hooks path]"
        guard ["install", "uninstall", "status"].contains(args[1]) else { throw AgentIPCError.failure(usage) }
        var configPath = agent.defaultPath, hooksPath: String?
        var index = 2
        while index < args.count {
            guard index + 1 < args.count else { throw AgentIPCError.failure(usage) }
            switch args[index] {
            case "--config": configPath = args[index + 1]
            case "--hooks": hooksPath = args[index + 1]
            default: throw AgentIPCError.failure(usage)
            }
            index += 2
        }
        if hooksPath != nil && (agent == .axCode || agent == .muse) { throw AgentIPCError.failure(usage) }
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let settings = agent.settings(path: configPath, hooksPath: hooksPath, executable: executable)
        switch args[1] {
        case "install": try settings.install(); print("Installed AkiTTY integration for \(agent.displayName) in \(configPath). \(agent.configHomeWarning)")
        case "uninstall": try settings.uninstall(); print("Removed AkiTTY's integration for \(agent.displayName). Other settings were left in place.")
        case "status": print("\(try settings.state()) (\(configPath))")
        default: throw AgentIPCError.failure(usage)
        }
        exit(0)
    }
    var request: [String: Any] = ["version": 1]
    if args == ["list"] { request["op"] = "list" }
    else if args.count == 2, args[0] == "list", let offset = Int(args[1]) { request["op"] = "list"; request["offset"] = offset }
    else if args.count == 3, args[0] == "request" {
        request["op"] = "request"; request["pane"] = args[1]; request["command"] = args[2]
    } else if args.count == 5, args[0] == "request", args[1] == "--id" {
        request["op"] = "request"; request["request_id"] = args[2]; request["pane"] = args[3]; request["command"] = args[4]
    } else if args.count == 2, args[0] == "status" {
        request["op"] = "status"; request["request_id"] = args[1]
    } else {
        throw AgentIPCError.failure("Usage: akitty-agent [--socket path] list [offset] | request [--id <request-id>] <pane-id> '<exact shell command>' | status <request-id> | mcp | claude-hook | codex-hook | grok-hook | muse-hook | kimi-hook | agy-hook | claude-hooks | codex-hooks install|uninstall|status [--settings path] | ax-code-mcp | grok-mcp | muse-mcp | kimi-mcp | agy-mcp install|uninstall|status [--config path] [--hooks path] | ax-code-report start|end <conversation-id>\nEvery request needs human approval. Reusing a request ID never runs a command again. Normal agent subprocesses are not intercepted.")
    }
    let reply = try LocalSocket.request(JSONSerialization.data(withJSONObject: request), path: path)
    FileHandle.standardOutput.write(reply); FileHandle.standardOutput.write(Data("\n".utf8))
    let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    exit(object?["ok"] as? Bool == true ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
