import AppKit
import XCTest
import MCP
@testable import AkittyKit

/// Exercises the bundled stdio executable with the official MCP client and a real native PTY.
final class MCPIntegrationTests: XCTestCase {
    @MainActor private func waitUntil(timeout: TimeInterval = 5, _ condition: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "MCPIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for native MCP effect"])
    }

    @MainActor func testStdioApproveDenyCancelAndEOFUseNativeAuthority() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/akitty-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        try "#!/bin/sh\nexec /bin/zsh -d -f -i\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        var preferences = TerminalPreferences(); preferences.shell = shell.path; preferences.directory = root.path; preferences.shellIntegration = false
        let terminal = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal; window.orderFront(nil)
        let path = root.appendingPathComponent("requests.sock").path
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        service.cooldownInterval = 0; service.startRecording(); try service.setEnabled(true)
        defer { service.stop(); terminal.shutdown(); window.close() }
        let integration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AkittyKit/Resources/shell-integration/akitty.zsh")
        try terminal.session.input("AKITTY_FOLDER_HISTORY=0; source '\(integration.path)'\r")
        try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }

        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = ProcessInfo.processInfo.environment["AKITTY_MCP_TEST_CLI"].map { URL(fileURLWithPath: $0) }
            ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("akitty-agent")
        process.arguments = ["--socket", path, "mcp"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        // Only the child owns these ends; retaining a parent copy masks EOF.
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        defer { if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        let client = Client(name: "akitty-integration-test", version: "1")
        let transport = StdioTransport(input: .init(rawValue: output.fileHandleForReading.fileDescriptor), output: .init(rawValue: input.fileHandleForWriting.fileDescriptor))
        _ = try await client.connect(transport: transport)
        let listing = try await client.listTools()
        XCTAssertEqual(Set(listing.tools.map(\.name)), ["list_panes", "request_command"])
        let listed: CallTool.Result = try await client.send(CallTool.request(.init(name: "list_panes"))).value
        let pane = try XCTUnwrap(listed.structuredContent?.objectValue?["data"]?.objectValue?["panes"]?.arrayValue?.first?.objectValue?["pane"]?.stringValue)

        for mode in ["denied", "approved", "cancelled", "eof"] {
            let marker = root.appendingPathComponent(mode)
            let text = "MCP_ONCE_$(printf should-not-expand)"
            let command = "printf '%s' '\(text)' >> '\(marker.path)'"
            let context = try await client.send(CallTool.request(.init(name: "request_command", arguments: ["pane": .string(pane), "command": .string(command)])))
            try await waitUntil { window.attachedSheet != nil }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "MCP must not run anything before native approval")
            if mode == "cancelled" {
                try await client.cancelRequest(context.requestID, reason: "test pending cancellation")
                do { _ = try await context.value; XCTFail("client request must terminate as cancelled") }
                catch is CancellationError {}
                try await waitUntil { window.attachedSheet == nil }
            } else if mode == "eof" {
                try input.fileHandleForWriting.close()
                try await waitUntil { window.attachedSheet == nil && !process.isRunning }
            } else {
                let sheet = try XCTUnwrap(window.attachedSheet)
                XCTAssertEqual(sheet.defaultButtonCell?.title, "Deny")
                window.endSheet(sheet, returnCode: mode == "approved" ? .alertFirstButtonReturn : .alertSecondButtonReturn)
                let receipt = try await context.value
                XCTAssertEqual(receipt.isError, mode != "approved")
                XCTAssertEqual(receipt.structuredContent?.objectValue?["automatic_retry_allowed"], false)
                XCTAssertEqual(receipt.structuredContent?.objectValue?["completion"], "unverified")
            }
            if mode == "approved" {
                try await waitUntil { (try? String(contentsOf: marker, encoding: .utf8)) == text }
                XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), text, "exact bytes must execute once")
                XCTAssertEqual(try terminal.session.snapshot()?.control?.agent, true)
                try terminal.session.reclaimControl()
                try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }
            } else {
                // Sheet dismissal precedes async native lease cleanup on cancellation.
                try await waitUntil { try terminal.session.snapshot()?.control?.owner == "human" }
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
                XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
            }
        }
        await client.disconnect()

        // Explicit opt-in only: normal verification never contacts a model provider.
        // This qualifies a named agent against native approval and a real PTY, beyond
        // the deterministic SDK client above. Both clients have their shell/write tools disabled.
        if let selected = ProcessInfo.processInfo.environment["AKITTY_MCP_LIVE_CLI"] {
            for kind in selected.split(separator: ",").map(String.init) {
                guard ["grok", "muse"].contains(kind) else {
                    throw NSError(domain: "MCPIntegrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Live CLI must be grok or muse"])
                }
                let workspace = root.appendingPathComponent(kind)
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
                let helper = try XCTUnwrap(process.executableURL).path
                let config: [String: Any] = ["mcpServers": ["akitty": ["command": helper, "args": ["--socket", path, "mcp"]]]]
                try JSONSerialization.data(withJSONObject: config).write(to: workspace.appendingPathComponent(".mcp.json"))
                let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git"); git.arguments = ["init", "-q", workspace.path]
                try git.run(); git.waitUntilExit(); XCTAssertEqual(git.terminationStatus, 0)
                let marker = root.appendingPathComponent("live-\(kind)")
                let command = "printf '%s' 'LIVE_MCP_ONCE' >> '\(marker.path)'"
                let prompt = "Use only the akitty MCP tools. First call list_panes, then call request_command exactly once for the returned pane with this exact command: \(command). Native approval will be handled in the test window. Do not use shell/file tools, retry, read output, or claim command success. Report only the dispatch receipt."
                let outputURL = root.appendingPathComponent("\(kind)-output"), errorURL = root.appendingPathComponent("\(kind)-error")
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
                defer { try? output.close(); try? error.close() }
                let agent = Process(); agent.executableURL = URL(fileURLWithPath: "/usr/bin/env"); agent.currentDirectoryURL = workspace
                if kind == "grok" {
                    agent.arguments = ["grok", "--trust", "--single", prompt, "--tools", "", "--no-subagents", "--max-turns", "8", "--output-format", "json"]
                } else {
                    agent.arguments = ["muse", "exec", "--preset", "empty", "--disable-shell", "--disable-write", "--disable-web-tools", "--disable-reminders", "--disable-request-user-input", "--no-foreign-personal-context", "--trust-workspace", "--disable-approval", "--max-model-steps", "8", "--json", prompt]
                }
                agent.standardInput = FileHandle.nullDevice; agent.standardOutput = output; agent.standardError = error
                try agent.run()
                defer { if agent.isRunning { agent.terminate() } }
                try await waitUntil(timeout: 180) { window.attachedSheet != nil || !agent.isRunning }
                let sheet = try XCTUnwrap(window.attachedSheet, "\(kind) did not request native approval: \((try? String(contentsOf: outputURL, encoding: .utf8)) ?? "")")
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                try await waitUntil { (try? String(contentsOf: marker, encoding: .utf8)) == "LIVE_MCP_ONCE" }
                try await waitUntil(timeout: 180) { window.attachedSheet != nil || !agent.isRunning }
                XCTAssertNil(window.attachedSheet, "agent must never request a duplicate command")
                guard !agent.isRunning else {
                    throw NSError(domain: "MCPIntegrationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Agent requested another approval instead of finishing"])
                }
                XCTAssertEqual(agent.terminationStatus, 0)
                XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "LIVE_MCP_ONCE")
                XCTAssertEqual(try terminal.session.snapshot()?.control?.agent, true, "client exit must not reclaim input")
                try terminal.session.reclaimControl()
                try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }
                print("Qualified \(kind): MCP list + request -> native approval -> exact one PTY effect; lease retained after client exit.")
            }
        }
    }
}
