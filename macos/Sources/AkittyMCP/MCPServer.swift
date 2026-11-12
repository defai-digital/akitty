import AgentIPC
import MCP

public enum AkittyMCPServer {
    public static func run(path: String = LocalSocket.defaultPath) async throws {
        let tools = TerminalTools(path: path)
        defer { tools.stop() }
        let handshake = Handshake()
        let server = Server(name: "akitty", version: "1", instructions: TerminalTools.instructions,
                            capabilities: .init(tools: .init()))
        // SDK 0.12.1's strict pre-initialize check throws before its response handler,
        // silently dropping that request. Check readiness inside our handlers instead.
        await server.withMethodHandler(ListTools.self) { _ in
            try await handshake.requireReady()
            return .init(tools: TerminalTools.tools)
        }
        await server.withMethodHandler(CallTool.self) {
            try await handshake.requireReady()
            return try await tools.call($0)
        }
        let transport = BoundedStdioTransport()
        try await server.start(transport: transport, initializeHook: { _, _ in await handshake.complete() })
        await server.waitUntilCompleted()
        tools.stop()
        await server.stop()
    }
}

private actor Handshake {
    private var ready = false
    func complete() { ready = true }
    func requireReady() throws {
        guard ready else { throw MCPError.invalidRequest("Initialize the AkiTTY MCP server before calling tools.") }
    }
}
