import AppKit
import XCTest
@testable import AgentIPC
@testable import AkittyKit

/// The release acceptance cases for several agents at once: load and fairness, three concurrent requests with a real
/// dispatch, and a request from one pane for another.
final class AgentAcceptanceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/akitty-accept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func waitUntil(timeout: TimeInterval = 5, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition did not become true")
    }
    @MainActor private func readyPane() throws -> TerminalView {
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        return terminal
    }
    @MainActor private func window(for view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        return window
    }
    @MainActor private func submit(_ service: AgentRequests, _ command: String, _ terminal: TerminalView, id: String) -> Task<Error?, Never> {
        Task { @MainActor in
            do { _ = try await service.request(command, in: terminal, origin: .siri, requestID: id); return nil } catch { return error }
        }
    }
    @MainActor private func state(_ service: AgentRequests, _ id: String) -> String? { service.status(of: id)?["state"] as? String }
    @MainActor private func sheetText(_ window: NSWindow) -> String {
        func texts(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
        }
        return window.attachedSheet?.contentView.map(texts)?.joined(separator: "\n") ?? ""
    }

    /// Eight panes each send eight requests. Every request is visibly queued quickly, the 65th is refused as full, and
    /// a pane nobody answers never holds up the others.
    @MainActor func testSixtyFourRequestsQueueQuicklyAndAnUnansweredPaneDoesNotBlockTheRest() async throws {
        _ = NSApplication.shared
        let root = try directory()
        let panes = try (0..<8).map { _ in try readyPane() }
        let windows = panes.map(window(for:))
        let extra = try readyPane(), extraWindow = window(for: extra)
        let service = AgentRequests(source: { panes + [extra] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("s.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); (panes + [extra]).forEach { $0.shutdown() }; (windows + [extraWindow]).forEach { $0.close() } }

        var started: [String: Date] = [:], visible: [String: TimeInterval] = [:]
        var tasks: [Task<Error?, Never>] = []
        for round in 0..<8 {
            for (index, pane) in panes.enumerated() {
                let id = "p\(index)-r\(round)"
                started[id] = Date(); tasks.append(submit(service, "echo \(id)", pane, id: id))
            }
        }
        try await waitUntil {
            for (id, start) in started where visible[id] == nil && self.state(service, id) != nil { visible[id] = Date().timeIntervalSince(start) }
            return visible.count == 64
        }
        let latencies = visible.values.sorted()
        XCTAssertEqual(latencies.count, 64)
        // Nearest-rank 95th percentile: the 61st of 64 samples.
        let p95 = try XCTUnwrap(latencies.isEmpty ? nil : latencies[Int((Double(latencies.count) * 0.95).rounded(.up)) - 1])
        XCTAssertLessThanOrEqual(p95, 0.25, "p95 from submission to a visible queue entry: \(p95) s")
        print("AKITTY_QUEUE_P95_MS \(Int(p95 * 1000)) max \(Int((latencies.last ?? 0) * 1000))")
        for pane in panes { XCTAssertEqual(service.pendingSummary(for: pane.session.id)?.count, 8) }

        // The 65th request finds AkiTTY full, with a clear reason, and is not recorded.
        do { _ = try await service.request("echo 65", in: extra, origin: .siri, requestID: "sixty-fifth"); XCTFail("the 65th request must be refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already has \(AgentRequests.appLimit)"), "\(error)") }
        XCTAssertNil(service.status(of: "sixty-fifth"))

        // Each window shows its own pane's head. Pane 0 is never answered; the other panes work through their queues.
        try await waitUntil { windows.allSatisfy { $0.attachedSheet != nil } }
        let untouched = try XCTUnwrap(windows[0].attachedSheet)
        for round in 0..<8 {
            for index in 1..<8 {
                let id = "p\(index)-r\(round)"
                try await waitUntil { self.state(service, id) == "awaiting_approval" && windows[index].attachedSheet != nil }
                windows[index].endSheet(try XCTUnwrap(windows[index].attachedSheet), returnCode: .alertSecondButtonReturn)
                try await waitUntil { self.state(service, id) == "denied" }
            }
        }
        for index in 1..<8 { XCTAssertNil(service.pendingSummary(for: panes[index].session.id)) }
        XCTAssertTrue(windows[0].attachedSheet === untouched, "the unanswered pane kept its sheet throughout")
        XCTAssertEqual(state(service, "p0-r0"), "awaiting_approval")
        XCTAssertEqual(service.pendingSummary(for: panes[0].session.id)?.count, 8)
        service.stop()
        for task in tasks { _ = await task.value }
        XCTAssertFalse(service.hasActiveRequest)
        for pane in panes { XCTAssertEqual(try pane.session.snapshot()?.control?.owner, "human") }
    }

    /// Panes A, B and C send requests together. The human approves C first, denies A and leaves B waiting: only C's
    /// command runs, exactly once, and B can still be answered afterwards.
    @MainActor func testThreeConcurrentRequestsApproveCDenyAAndBStaysAnswerable() async throws {
        _ = NSApplication.shared
        let root = try directory()
        var preferences = TerminalPreferences(); preferences.shell = "/bin/zsh"; preferences.directory = root.path; preferences.shellIntegration = false
        let c = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let a = try readyPane(), b = try readyPane()
        let windowA = window(for: a), windowB = window(for: b), windowC = window(for: c)
        let service = AgentRequests(source: { [a, b, c] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("s.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); [a, b, c].forEach { $0.shutdown() }; [windowA, windowB, windowC].forEach { $0.close() } }
        let integration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AkittyKit/Resources/shell-integration/akitty.zsh").path
        try c.session.input("AKITTY_FOLDER_HISTORY=0; source '\(integration)'\r", paste: false)
        try await waitUntil { try c.session.snapshot()?.shell?.ready == true }

        let markerA = root.appendingPathComponent("a.txt"), markerC = root.appendingPathComponent("c.txt")
        let commandC = "printf 'C' >> '\(markerC.path)'"
        let taskA = submit(service, "printf 'A' >> '\(markerA.path)'", a, id: "A")
        let taskB = submit(service, "echo B", b, id: "B")
        let taskC = submit(service, commandC, c, id: "C")
        try await waitUntil { [windowA, windowB, windowC].allSatisfy { $0.attachedSheet != nil } }

        windowC.endSheet(try XCTUnwrap(windowC.attachedSheet), returnCode: .alertFirstButtonReturn)
        let errorC = await taskC.value
        XCTAssertNil(errorC)
        windowA.endSheet(try XCTUnwrap(windowA.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await taskA.value
        XCTAssertEqual(state(service, "C"), "dispatched")
        XCTAssertEqual(state(service, "A"), "denied")
        XCTAssertEqual(state(service, "B"), "awaiting_approval", "B is untouched by the other answers")

        try await waitUntil { (try? String(contentsOf: markerC, encoding: .utf8)) == "C" }
        func runs() throws -> Int {
            let history = try JSONSerialization.jsonObject(with: c.session.call("command_history")) as! [String: Any]
            return (history["commands"] as! [[String: Any]]).filter { $0["command"] as? String == commandC }.count
        }
        try await waitUntil { try runs() == 1 }
        // A second dispatch would append another C before a later command the shell runs after it.
        try c.session.reclaimControl()
        let settled = root.appendingPathComponent("settled")
        try c.session.input("sleep 0.3; : > '\(settled.path)'\r", paste: false)
        try await waitUntil { FileManager.default.fileExists(atPath: settled.path) }
        XCTAssertEqual(try String(contentsOf: markerC, encoding: .utf8), "C", "C ran exactly once")
        XCTAssertEqual(try runs(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerA.path), "the denied command never ran")

        windowB.endSheet(try XCTUnwrap(windowB.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await taskB.value
        XCTAssertEqual(state(service, "B"), "denied")
        // A repeated click or a resent ID finds the recorded outcome instead of acting again.
        do { _ = try await service.request(commandC, in: c, origin: .siri, requestID: "C"); XCTFail("a resent ID must not run again") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already received"), "\(error)") }
        XCTAssertEqual(state(service, "C"), "dispatched")
    }

    /// AkiTTY's AX Code plugin, loaded the way AX Code loads it, reports the conversation of the pane it runs in
    /// through the bundled companion, and a session that AX Code deletes ends the report.
    @MainActor func testAXCodePluginReportsTheConversationOfItsPane() async throws {
        _ = NSApplication.shared
        guard let node = AgentCLI.locate("node", in: AgentCLI.searchPath()) else {
            throw XCTSkip("Node is needed to load the AX Code plugin")
        }
        let root = try directory()
        var preferences = TerminalPreferences(); preferences.shell = "/bin/zsh"; preferences.directory = root.path; preferences.shellIntegration = false
        let pane = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let window = window(for: pane)
        let path = root.appendingPathComponent("s.sock").path
        let service = AgentRequests(source: { [pane] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        try service.setEnabled(true)
        defer { service.stop(); pane.shutdown(); window.close() }
        try await waitUntil { (try pane.session.shellState()).tty_device != nil }

        // A wrapper fixes the socket path, as the default socket would be in the app.
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("akitty-agent").path
        let wrapper = root.appendingPathComponent("akitty-agent")
        try Data("#!/bin/sh\nexec '\(cli)' --socket '\(path)' \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let settings = AXCodeMCPSettings(path: root.appendingPathComponent("ax-code/ax-code.json").path, executable: wrapper.path)
        try settings.install()
        let driver = root.appendingPathComponent("drive.mjs")
        let id = "ses_-e5e0a0370dbffeRG78fg4pj0f"
        try Data("""
        const { AkittyConversationReport } = await import(process.argv[2]);
        const hooks = await AkittyConversationReport();
        const send = (type, properties) => hooks.event({ event: { type, properties } });
        const sessionID = process.argv[5] || "\(id)";
        // A fork the person continues is reported; a sub-agent that runs while its parent is busy is not.
        await send("session.created", { info: { id: "ses_fork", parentID: "ses_old" } });
        await send("session.status", { sessionID: "ses_fork", status: { type: "busy" } });
        await send("session.status", { sessionID: "ses_fork", status: { type: "idle" } });
        await new Promise((resolve) => setTimeout(resolve, 1500));
        await send("session.created", { info: { id: sessionID } });
        await send("session.status", { sessionID, status: { type: "busy" } });
        await send("session.created", { info: { id: "ses_child", parentID: sessionID } });
        await send("session.status", { sessionID: "ses_child", status: { type: "busy" } });
        await new Promise((resolve) => setTimeout(resolve, Number(process.argv[3])));
        if (process.argv[4] === "delete") await send("session.deleted", { info: { id: sessionID } });
        if (process.argv[4] === "exit") process.exit(0);
        await new Promise((resolve) => setTimeout(resolve, 500));

        """.utf8).write(to: driver)
        try pane.session.input("'\(node)' '\(driver.path)' 'file://\(settings.pluginPath)' 3000 delete\r", paste: false)
        // A slow companion may arrive after the final state; sequenced reports intentionally drop that stale fork.
        try await waitUntil(timeout: 10) { service.agentSessions[pane.session.id]?.sessionID == id }
        XCTAssertTrue(service.lastReport(agent: "ax-code")?.hasPrefix("ses_-e5e") == true, service.lastReport(agent: "ax-code") ?? "")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(service.agentSessions[pane.session.id]?.sessionID, id, "the sub-agent session is never reported")
        try await waitUntil(timeout: 10) { service.agentSessions[pane.session.id]?.ended == true }
        let events = String(decoding: try service.store.export(), as: UTF8.self)
        XCTAssertTrue(events.contains("\"agent_reported\":\"ax-code\""), events)
        XCTAssertFalse(events.contains(id), "conversation IDs stay out of the event timeline")

        // A forced AX Code exit sends a final higher-sequence end, even if an earlier start arrives afterwards.
        let exitID = "ses_exit"
        try pane.session.input("'\(node)' '\(driver.path)' 'file://\(settings.pluginPath)' 0 exit \(exitID)\r", paste: false)
        try await waitUntil(timeout: 10) {
            service.agentSessions[pane.session.id]?.sessionID == exitID && service.agentSessions[pane.session.id]?.ended == true
        }
    }

    /// A program in pane A asks for a command in pane B: it queues on B, and B's sheet names A as the source.
    @MainActor func testRequestFromAnotherPaneQueuesOnTheTargetAndNamesTheSource() async throws {
        _ = NSApplication.shared
        let root = try directory()
        var preferences = TerminalPreferences(); preferences.shell = "/bin/zsh"; preferences.directory = root.path; preferences.shellIntegration = false
        let source = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let target = try readyPane()
        let sourceWindow = window(for: source), targetWindow = window(for: target)
        let path = root.appendingPathComponent("s.sock").path
        let service = AgentRequests(source: { [source, target] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        service.cooldownInterval = 0; try service.setEnabled(true)
        defer { service.stop(); source.shutdown(); target.shutdown(); sourceWindow.close(); targetWindow.close() }
        try await waitUntil { (try source.session.shellState()).tty_device != nil }

        let list = try await Task.detached { try LocalSocket.request(Data("{\"version\":1,\"op\":\"list\"}".utf8), path: path) }.value
        let panes = ((try JSONSerialization.jsonObject(with: list) as! [String: Any])["data"] as! [String: Any])["panes"] as! [[String: Any]]
        let targetID = try XCTUnwrap(panes.compactMap { $0["pane"] as? String }.first { $0.hasSuffix("/\(target.session.id)") })
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("akitty-agent").path
        let done = root.appendingPathComponent("done")
        try source.session.input("'\(cli)' --socket '\(path)' request '\(targetID)' 'echo from-a'; : > '\(done.path)'\r", paste: false)
        try await waitUntil { targetWindow.attachedSheet != nil }
        XCTAssertNil(sourceWindow.attachedSheet, "the request queues on its target, not on the requesting pane")
        let text = sheetText(targetWindow)
        XCTAssertTrue(text.contains("Requested by a program started in another pane, Terminal \(source.session.id)"), text)
        XCTAssertTrue(text.contains("runs in Terminal \(target.session.id)"), text)
        targetWindow.endSheet(try XCTUnwrap(targetWindow.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await waitUntil { FileManager.default.fileExists(atPath: done.path) }
        let events = String(decoding: try service.store.export(), as: UTF8.self)
        XCTAssertTrue(events.contains("\"source_pane_session_id\":\(source.session.id)"), events)

        // A caller outside every pane is named as such.
        let outside = try JSONSerialization.data(withJSONObject: ["version": 1, "op": "request", "pane": targetID, "command": "echo outside"])
        let pending = Task.detached { try LocalSocket.request(outside, path: path) }
        try await waitUntil { targetWindow.attachedSheet != nil }
        XCTAssertTrue(sheetText(targetWindow).contains("outside every AkiTTY pane"))
        targetWindow.endSheet(try XCTUnwrap(targetWindow.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = try? await pending.value
        XCTAssertEqual(AgentRequests.describe(.pane(7), target: 7), "Requested by a program started in this pane. The command runs here, in Terminal 7.")
        XCTAssertNil(AgentRequests.describe(.notLocal, target: 7))
    }
}
