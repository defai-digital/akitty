import Foundation
import AgentIPC

do {
    var args = Array(CommandLine.arguments.dropFirst())
    var path = LocalSocket.defaultPath
    if args.count >= 2, args[0] == "--socket" { path = args[1]; args.removeFirst(2) }
    var request: [String: Any] = ["version": 1]
    if args == ["list"] { request["op"] = "list" }
    else if args.count == 2, args[0] == "list", let offset = Int(args[1]) { request["op"] = "list"; request["offset"] = offset }
    else if args.count == 3, args[0] == "request" {
        request["op"] = "request"; request["pane"] = args[1]; request["command"] = args[2]
    } else {
        throw AgentIPCError.failure("Usage: akitty-agent [--socket path] list [offset] | akitty-agent [--socket path] request <pane-id> '<exact shell command>'\nEvery request needs human approval. Normal agent subprocesses are not intercepted.")
    }
    let reply = try LocalSocket.request(JSONSerialization.data(withJSONObject: request), path: path)
    FileHandle.standardOutput.write(reply); FileHandle.standardOutput.write(Data("\n".utf8))
    let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    exit(object?["ok"] as? Bool == true ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
