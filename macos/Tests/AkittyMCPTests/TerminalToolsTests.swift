import XCTest
import Foundation
import AgentIPC
@testable import AkittyMCP
import MCP

final class TerminalToolsTests: XCTestCase {
    private func socketDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/akitty-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    func testSurfaceAndAnnotations() {
        XCTAssertEqual(TerminalTools.tools.map(\.name), ["list_panes", "request_command"])
        XCTAssertEqual(TerminalTools.tools[0].annotations.readOnlyHint, true)
        XCTAssertEqual(TerminalTools.tools[1].annotations.destructiveHint, true)
        XCTAssertEqual(TerminalTools.tools[1].annotations.idempotentHint, false)
    }

    func testValidationPreservesExactCommandAndRejectsBadArguments() throws {
        let command = "printf '%s' 'quotes \" $() ; & | > < \\ and 中文'"
        let data = try TerminalTools.payload(.init(name: "request_command", arguments: ["pane": "launch/1", "command": .string(command)]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["command"] as? String, command)
        let invalid: [[String: Value]] = [[:], ["pane": "x"], ["pane": "x", "command": "pwd", "approval": true],
            ["pane": true, "command": "pwd"], ["pane": "", "command": "pwd"],
            ["pane": "x", "command": ""], ["pane": "x", "command": "  "],
            ["pane": "x", "command": "pwd\nls"], ["pane": "x", "command": "\u{0}"],
            ["pane": "x", "command": "pwd\u{200b}"],
            ["pane": "x", "command": .string(String(repeating: "a", count: 4097))],
            ["pane": "x", "command": .string(String(repeating: "中", count: 1366))]]
        for arguments in invalid { XCTAssertThrowsError(try TerminalTools.payload(.init(name: "request_command", arguments: arguments))) }
        XCTAssertNoThrow(try TerminalTools.payload(.init(name: "request_command", arguments: ["pane": "x", "command": .string(String(repeating: "a", count: 4096))])))
        for offset: Value in [true, -1, 65, 1.5, "0", .null] {
            XCTAssertThrowsError(try TerminalTools.payload(.init(name: "list_panes", arguments: ["offset": offset])))
        }
        XCTAssertThrowsError(try TerminalTools.payload(.init(name: "list_panes", arguments: ["actor": "agent"])))
        XCTAssertThrowsError(try TerminalTools.payload(.init(name: "control_reclaim")))
    }

    func testDisabledServiceDoesNotClaimSuccessOrRetry() async throws {
        let tools = TerminalTools(path: "/tmp/akitty-absent-\(UUID().uuidString)")
        let result = try await tools.call(.init(name: "request_command", arguments: ["pane": "x", "command": "pwd"]))
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?.objectValue?["automatic_retry_allowed"], false)
        XCTAssertEqual(result.structuredContent?.objectValue?["completion"], "unverified")
    }

    func testSocketPaginationAndDispatchReceiptAreForwardedWithoutRetry() async throws {
        let root = try socketDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("requests.sock").path
        let server = LocalRequestServer(path: path)
        let count = Counter()
        try server.start { data, _ in
            await count.increment()
            let input = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            if input["op"] as? String == "list" {
                let offset = input["offset"] as? Int ?? 0
                return Data("{\"version\":1,\"ok\":true,\"data\":{\"offset\":\(offset),\"next_offset\":\(offset == 0 ? "16" : "null"),\"panes\":[]}}".utf8)
            }
            return Data("{\"version\":1,\"ok\":true,\"data\":{\"accepted\":true,\"input_remains_leased\":true,\"completion_untrusted\":true}}".utf8)
        }
        defer { server.stop(); try? FileManager.default.removeItem(atPath: path + ".lock") }
        let tools = TerminalTools(path: path)
        let first = try await tools.call(.init(name: "list_panes"))
        XCTAssertEqual(first.structuredContent?.objectValue?["data"]?.objectValue?["next_offset"], 16)
        let second = try await tools.call(.init(name: "list_panes", arguments: ["offset": 16]))
        XCTAssertEqual(second.structuredContent?.objectValue?["data"]?.objectValue?["offset"], 16)
        let receipt = try await tools.call(.init(name: "request_command", arguments: ["pane": "test/1", "command": "pwd"]))
        XCTAssertEqual(receipt.isError, false)
        XCTAssertEqual(receipt.structuredContent?.objectValue?["completion"], "unverified")
        XCTAssertEqual(receipt.structuredContent?.objectValue?["automatic_retry_allowed"], false)
        let total = await count.value
        XCTAssertEqual(total, 3)
        tools.stop()
    }

    func testLostReceiptIsOneAttemptAndNeverSuccess() async throws {
        let root = try socketDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("requests.sock").path
        let server = LocalRequestServer(path: path), count = Counter()
        try server.start { _, _ in
            await count.increment()
            return Data("not-json".utf8)
        }
        defer { server.stop(); try? FileManager.default.removeItem(atPath: path + ".lock") }
        let tools = TerminalTools(path: path)
        let result = try await tools.call(.init(name: "request_command", arguments: ["pane": "x", "command": "pwd"]))
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?.objectValue?["automatic_retry_allowed"], false)
        let total = await count.value
        XCTAssertEqual(total, 1)
    }

    func testCancellationBusyAndShutdownDisconnectWithoutRetry() async throws {
        let root = try socketDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("requests.sock").path
        let server = LocalRequestServer(path: path), count = Counter()
        try server.start { _, peer in
            await count.increment()
            while peer.connected && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            await count.disconnected()
            return Data("{\"version\":1,\"ok\":false,\"error\":\"cancelled\"}".utf8)
        }
        defer { server.stop() }
        let cancelled = LocalSocketRequest(); cancelled.cancel()
        do { _ = try await cancelled.send(Data("{}".utf8), path: path); XCTFail("pre-cancelled request must not connect") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        let tools = TerminalTools(path: path)
        let params = CallTool.Parameters(name: "request_command", arguments: ["pane": "x", "command": "pwd"])
        let first = Task { try await tools.call(params) }
        try await waitUntil { await count.value == 1 }
        let busy = try await tools.call(params)
        XCTAssertEqual(busy.isError, true)
        first.cancel()
        do { _ = try await first.value; XCTFail("expected cancellation") } catch is CancellationError {}
        try await waitUntil { await count.disconnects == 1 }
        let second = Task { try await tools.call(params) }
        try await waitUntil { await count.value == 2 }
        tools.stop()
        let stopped = try await second.value
        XCTAssertEqual(stopped.isError, true)
        try await waitUntil { await count.disconnects == 2 }
        let total = await count.value
        XCTAssertEqual(total, 2, "busy, cancellation, and shutdown must not resend")
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "TerminalToolsTests", code: 1)
    }
}

private actor Counter {
    var value = 0
    var disconnects = 0
    func increment() { value += 1 }
    func disconnected() { disconnects += 1 }
}
