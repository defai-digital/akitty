import AppKit
import XCTest
import Darwin
@testable import AgentIPC
@testable import AkittyKit

final class AgentRequestTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/akitty-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    @MainActor private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<300 {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition did not become true")
    }
    @MainActor func testRealSocketRejectsAuthorityOperationsAndDenyDispatchesNothing() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        service.startRecording(); try service.setEnabled(true)
        defer { service.stop(); terminal.shutdown(); window.close() }
        let path = root.appendingPathComponent("requests.sock").path
        func send(_ request: [String: Any]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: request)
            let response = try await Task.detached { try LocalSocket.request(data, path: path) }.value
            return try JSONSerialization.jsonObject(with: response) as! [String: Any]
        }
        let listing = try await send(["version": 1, "op": "list"])
        let panes = (listing["data"] as! [String: Any])["panes"] as! [[String: Any]]
        let pane = try XCTUnwrap(panes.first?["pane"] as? String)
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("akitty-agent")
        let cli = try await Task.detached { () throws -> (Data, Int32) in
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = ["--socket", path, "list"]
            process.standardOutput = output; process.standardError = Pipe()
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (data, process.terminationStatus)
        }.value
        XCTAssertEqual(cli.1, 0)
        let cliObject = try JSONSerialization.jsonObject(with: cli.0) as! [String: Any]
        let cliPanes = (cliObject["data"] as! [String: Any])["panes"] as! [[String: Any]]
        XCTAssertEqual(cliPanes.first?["pane"] as? String, pane)
        for request: [String: Any] in [["version": 1, "op": "command_authorize"], ["version": 1, "op": "control_reclaim"],
            ["version": true, "op": "list"], ["version": 1, "op": "list", "actor": "Codex"],
            ["version": 1, "op": "request", "pane": "old/1", "command": "echo bad"]] {
            let result = try await send(request); XCTAssertEqual(result["ok"] as? Bool, false)
        }
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        let request = Task { try await send(["version": 1, "op": "request", "pane": pane, "command": "echo secret-value"]) }
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(sheet.defaultButtonCell?.title, "Deny")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        let denied = try await request.value
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
        let events = String(decoding: try service.store.export(), as: UTF8.self)
        XCTAssertFalse(events.contains("secret-value")); XCTAssertTrue(events.contains("command_sha256"))
        XCTAssertTrue(events.contains("denied")); XCTAssertFalse(events.contains("\"event\":\"dispatched\""))
    }

    @MainActor func testActualPTYApprovedCommandDispatchesOnceAndReclaimDoesNotStopProcess() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var preferences = TerminalPreferences(); preferences.shell = "/bin/zsh"; preferences.directory = root.path; preferences.shellIntegration = false
        let terminal = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = terminal
        let path = root.appendingPathComponent("requests.sock").path
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        service.startRecording(); try service.setEnabled(true)
        defer { service.stop(); terminal.shutdown(); window.close() }
        let integration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AkittyKit/Resources/shell-integration/akitty.zsh").path
        try terminal.session.input("source '\(integration)'\r", paste: false)
        try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }
        let listData = Data("{\"version\":1,\"op\":\"list\"}".utf8)
        let response = try await Task.detached { try LocalSocket.request(listData, path: path) }.value
        let object = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        let pane = (((object["data"] as! [String: Any])["panes"] as! [[String: Any]])[0]["pane"] as! String)
        let marker = root.appendingPathComponent("executed.txt")
        let command = "printf 'MANAGED_ONCE' >> '\(marker.path)'; sleep 5"
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "op": "request", "pane": pane, "command": command])
        let pending = Task.detached { try LocalSocket.request(data, path: path) }
        try await waitUntil { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let receipt = try JSONSerialization.jsonObject(with: try await pending.value) as! [String: Any]
        XCTAssertEqual(receipt["ok"] as? Bool, true)
        XCTAssertEqual((receipt["data"] as? [String: Any])?["input_remains_leased"] as? Bool, true)
        XCTAssertThrowsError(try terminal.session.input("human", paste: false))
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "MANAGED_ONCE", "execution is established by a file effect, not terminal text")
        try terminal.session.reclaimControl()
        XCTAssertEqual(try terminal.session.snapshot()?.exited, false)
        XCTAssertEqual(try terminal.session.snapshot()?.shell?.ready, false, "reclaim leaves the running sleep alive")
        try terminal.session.input("\u{3}", paste: false)
        try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }
        let history = try JSONSerialization.jsonObject(with: terminal.session.call("command_history")) as! [String: Any]
        let commands = history["commands"] as! [[String: Any]]
        XCTAssertEqual(commands.filter { $0["command"] as? String == command }.count, 1)
    }

    @MainActor func testApprovalTimeoutCannotGrantAndStatusReportsRemainUnverified() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let alert = AgentCommandHost.approvalAlert(AgentCommandRequest(sessionID: 1, actor: "local process", command: "echo hi", cwd: nil))
        let accepted = await AgentRequests.present(alert, in: window, timeout: 0.02)
        XCTAssertFalse(accepted)
        let session = try TerminalSession(headless: true); defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}]7501;state=blocked:kind=permission:app=agent\u{7}"])
        let snapshot = try XCTUnwrap(session.snapshot())
        XCTAssertEqual(snapshot.control?.owner, "human")
        XCTAssertTrue(AgentOverviewRow(sessionID: session.id, snapshot: snapshot).programStatus?.contains("blocked") == true)
        XCTAssertEqual(snapshot.program_status?.untrusted, true)
    }

    @MainActor func testLateApprovalCannotBeatADelayedTimeoutCallback() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let alert = AgentCommandHost.approvalAlert(AgentCommandRequest(sessionID: 1, actor: "test", command: "echo late", cwd: nil))
        var instant: TimeInterval = 0
        let pending = Task { await AgentRequests.present(alert, in: window, timeout: 30, now: { instant }) }
        try await waitUntil { window.attachedSheet != nil }
        // Advance past the absolute deadline before the real timer fires. A short
        // real timeout could remove the sheet before a loaded runner observes it.
        instant = 31
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let accepted = await pending.value
        XCTAssertFalse(accepted, "the absolute deadline must hold even before the timeout callback runs")
    }

    @MainActor func testClosingTheWindowUnderAnApprovalSheetResolvesAsDenied() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let alert = AgentCommandHost.approvalAlert(AgentCommandRequest(sessionID: 1, actor: "test", command: "echo gone", cwd: nil))
        let pending = Task { await AgentRequests.present(alert, in: window, timeout: 30) }
        try await waitUntil { window.attachedSheet != nil }
        // A shell exiting closes its window directly, bypassing the sheet guard in windowShouldClose.
        window.close()
        let accepted = await pending.value
        XCTAssertFalse(accepted, "a request whose window went away must resolve, and never as approved")
    }

    @MainActor func testCompletedApprovalReleasesItsValidationContext() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        var alert: NSAlert? = AgentCommandHost.approvalAlert(AgentCommandRequest(sessionID: 1, actor: "test", command: "echo cleanup", cwd: nil))
        weak var context: NSObject?
        var pending: Task<Bool, Never>? = {
            let retained = NSObject(), displayed = alert!
            context = retained
            return Task { await AgentRequests.present(displayed, in: window, timeout: 30, valid: { retained.isEqual(retained) }) }
        }()
        try await waitUntil { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        let accepted = await pending!.value
        XCTAssertFalse(accepted)
        pending = nil; alert = nil; window.close()
        try await waitUntil { context == nil }
    }

    @MainActor func testDisconnectDisableAndCooldownCannotAuthorize() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        let path = root.appendingPathComponent("requests.sock").path
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        service.cooldownInterval = 0; try service.setEnabled(true)
        defer { service.stop(); terminal.shutdown(); window.close() }
        let listData = Data("{\"version\":1,\"op\":\"list\"}".utf8)
        let listing = try await Task.detached { try LocalSocket.request(listData, path: path) }.value
        let object = try JSONSerialization.jsonObject(with: listing) as! [String: Any]
        let pane = (((object["data"] as! [String: Any])["panes"] as! [[String: Any]])[0]["pane"] as! String)
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        let request = try JSONSerialization.data(withJSONObject: ["version": 1, "op": "request", "pane": pane, "command": "echo no"])
        let fd = try LocalSocket.descriptor()
        XCTAssertEqual(try LocalSocket.withAddress(path) { Darwin.connect(fd, $0, $1) }, 0)
        try LocalSocket.writeFrame(request, to: fd)
        try await waitUntil { window.attachedSheet != nil }
        Darwin.close(fd)
        try await waitUntil { try window.attachedSheet == nil && terminal.session.snapshot()?.control?.agent == false }
        service.cooldownInterval = 60
        let pending = Task.detached { try LocalSocket.request(request, path: path) }
        try await waitUntil { window.attachedSheet != nil }
        try service.setEnabled(false)
        do {
            let reply = try JSONSerialization.jsonObject(with: try await pending.value) as! [String: Any]
            XCTAssertEqual(reply["ok"] as? Bool, false)
        } catch { XCTAssertTrue(error.localizedDescription.contains("Dispatch outcome may be unknown")) }
        try await waitUntil { try window.attachedSheet == nil && terminal.session.snapshot()?.control?.agent == false }
        try service.setEnabled(true)
        let limited = try await Task.detached { try LocalSocket.request(request, path: path) }.value
        XCTAssertTrue(String(decoding: limited, as: UTF8.self).contains("rate limited"))
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
    }

    @MainActor func testInvisibleCommandFormattingFailsBeforeRequestRecording() throws {
        for scalar in ["\u{202e}", "\u{2066}", "\u{200b}", "\u{feff}"] { XCTAssertThrowsError(try AgentCommandHost.validateCommand("echo \(scalar)hidden")) }
        let command = "echo " + String(repeating: "long-command ", count: 200)
        let alert = AgentCommandHost.approvalAlert(AgentCommandRequest(sessionID: 1, actor: "local process", command: command, cwd: nil))
        let stack = try XCTUnwrap(alert.accessoryView as? NSStackView)
        let scroll = try XCTUnwrap(stack.views.first as? NSScrollView)
        XCTAssertEqual((scroll.documentView as? NSTextView)?.string, command)
    }

    @MainActor func testPaneListPaginatesWithoutLeakingOutput() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let terminals = try (0..<17).map { _ in try TerminalView(headless: true, forceSoftware: true) }
        let path = root.appendingPathComponent("socket").path
        let service = AgentRequests(source: { terminals }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        try service.setEnabled(true)
        defer { service.stop(); terminals.forEach { $0.shutdown() } }
        for (offset, count) in [(0, 16), (16, 1)] {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "op": "list", "offset": offset])
            let reply = try await Task.detached { try LocalSocket.request(data, path: path) }.value
            XCTAssertLessThanOrEqual(reply.count, LocalSocket.frameLimit)
            let result = (try JSONSerialization.jsonObject(with: reply) as! [String: Any])["data"] as! [String: Any]
            let panes = result["panes"] as! [[String: Any]]
            XCTAssertEqual(panes.count, count)
            XCTAssertTrue(panes.allSatisfy { $0["output"] == nil && $0["lease"] == nil && $0["cwd"] == nil })
            if offset == 0 { XCTAssertEqual(result["next_offset"] as? Int, 16) }
            else { XCTAssertTrue(result["next_offset"] is NSNull) }
        }
    }

    @MainActor func testUnknownDispatchReceiptPreservesLeaseWithoutRetry() async throws {
        let session = try TerminalSession(headless: true); defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        var attempts = 0
        let host = AgentCommandHost(session: session) { _, _, _ in
            attempts += 1; throw AkittyError.core("simulated receipt decode failure after dispatch boundary")
        }
        do { _ = try await host.execute(actor: "test", command: "echo hi") { _ in true }; XCTFail("missing receipt cannot imply success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Dispatch outcome is unknown")); XCTAssertTrue(error.localizedDescription.contains("Do not retry")) }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(try session.snapshot()?.control?.agent, true)
        try session.reclaimControl()
    }
}
