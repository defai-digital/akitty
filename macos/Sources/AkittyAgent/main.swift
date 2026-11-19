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
    if args == [ClaudeHookSettings.subcommand] {
        // Never fail the agent: any error means no output, and Claude Code keeps its own prompt.
        let input = FileHandle.standardInput.readData(ofLength: ClaudeHook.inputLimit + 1)
        if let output = ClaudeHook.respond(to: input, path: path) {
            FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(0)
    }
    if args.first == "claude-hooks", args.count >= 2 {
        var settingsPath = ClaudeHookSettings.defaultPath
        if args.count == 4, args[2] == "--settings" { settingsPath = args[3] } else if args.count != 2 { throw AgentIPCError.failure("Usage: akitty-agent claude-hooks install|uninstall|status [--settings path]") }
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let settings = ClaudeHookSettings(path: settingsPath, executable: executable)
        switch args[1] {
        case "install": try settings.install(); print("Installed AkiTTY hooks for Claude Code in \(settingsPath). Restart running Claude Code sessions to load them.")
        case "uninstall": try settings.uninstall(); print("Removed AkiTTY hooks from \(settingsPath). Other hooks were left in place.")
        case "status": print("\(try settings.state()) (\(settingsPath))")
        default: throw AgentIPCError.failure("Usage: akitty-agent claude-hooks install|uninstall|status [--settings path]")
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
        throw AgentIPCError.failure("Usage: akitty-agent [--socket path] list [offset] | request [--id <request-id>] <pane-id> '<exact shell command>' | status <request-id> | mcp | claude-hook | claude-hooks install|uninstall|status [--settings path]\nEvery request needs human approval. Reusing a request ID never runs a command again. Normal agent subprocesses are not intercepted.")
    }
    let reply = try LocalSocket.request(JSONSerialization.data(withJSONObject: request), path: path)
    FileHandle.standardOutput.write(reply); FileHandle.standardOutput.write(Data("\n".utf8))
    let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    exit(object?["ok"] as? Bool == true ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
