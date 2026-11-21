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
        // Approval only prompts on an on-screen window; an ordered-out one must fail closed.
        window.orderFront(nil)
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
        // The printed value must be copyable as-is: no JSON `\/` escape inside the pane ID (issue #26).
        XCTAssertTrue(String(decoding: cli.0, as: UTF8.self).contains("\"pane\":\"\(pane)\""))
        for request: [String: Any] in [["version": 1, "op": "command_authorize"], ["version": 1, "op": "control_reclaim"],
            ["version": true, "op": "list"], ["version": 1, "op": "list", "actor": "Codex"],
            ["version": 1, "op": "request", "pane": "old/1", "command": "echo bad"]] {
            let result = try await send(request); XCTAssertEqual(result["ok"] as? Bool, false)
        }
        let stale = try await send(["version": 1, "op": "request", "pane": "old/1", "command": "echo bad"])
        XCTAssertTrue((stale["error"] as? String)?.contains("Run list again") == true)
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        // A hand-copied escaped ID with stray whitespace still reaches the approval sheet.
        let copied = " " + pane.replacingOccurrences(of: "/", with: "\\/") + "\n"
        let request = Task { try await send(["version": 1, "op": "request", "pane": copied, "command": "echo secret-value"]) }
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
        window.orderFront(nil)
        let path = root.appendingPathComponent("requests.sock").path
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        service.startRecording(); try service.setEnabled(true)
        defer { service.stop(); terminal.shutdown(); window.close() }
        let integration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AkittyKit/Resources/shell-integration/akitty.zsh").path
        try terminal.session.input("AKITTY_FOLDER_HISTORY=0; source '\(integration)'\r", paste: false)
        try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }
        let listData = Data("{\"version\":1,\"op\":\"list\"}".utf8)
        let response = try await Task.detached { try LocalSocket.request(listData, path: path) }.value
        let object = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        let listEnvelope = try XCTUnwrap(object["data"] as? [String: Any])
        let listed = try XCTUnwrap(listEnvelope["panes"] as? [[String: Any]])
        let pane = try XCTUnwrap(listed[0]["pane"] as? String)
        XCTAssertEqual(listed[0]["shell_ready"] as? Bool, true)
        let directory = listed[0]["directory_untrusted"] as? String
        XCTAssertTrue(directory == root.path || directory == "/private" + root.path, "accept the shell's canonical /private/tmp spelling")
        XCTAssertTrue(listEnvelope.keys.contains("source_pane"))
        XCTAssertTrue(listEnvelope["source_pane"] is NSNull, "this caller is outside every AkiTTY pane")
        let marker = root.appendingPathComponent("executed.txt")
        // Keep the marker empty briefly to exercise redirection creating it before printf writes.
        let command = ": >> '\(marker.path)'; sleep 0.1; printf 'MANAGED_ONCE' >> '\(marker.path)'; sleep 5"
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "op": "request", "pane": pane, "command": command])
        let pending = Task.detached { try LocalSocket.request(data, path: path) }
        try await waitUntil { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let receipt = try JSONSerialization.jsonObject(with: try await pending.value) as! [String: Any]
        XCTAssertEqual(receipt["ok"] as? Bool, true)
        XCTAssertEqual((receipt["data"] as? [String: Any])?["input_remains_leased"] as? Bool, true)
        XCTAssertThrowsError(try terminal.session.input("human", paste: false))
        try await waitUntil { (try? String(contentsOf: marker, encoding: .utf8))?.hasPrefix("MANAGED_ONCE") == true }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "MANAGED_ONCE", "execution is established by a file effect, not terminal text")
        try terminal.session.reclaimControl()
        XCTAssertEqual(try terminal.session.snapshot()?.exited, false)
        XCTAssertEqual(try terminal.session.snapshot()?.shell?.ready, false, "reclaim leaves the running sleep alive")
        try terminal.session.input("\u{3}", paste: false)
        try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }
        let history = try JSONSerialization.jsonObject(with: terminal.session.call("command_history")) as! [String: Any]
        let commands = history["commands"] as! [[String: Any]]
        XCTAssertEqual(commands.filter { $0["command"] as? String == command }.count, 1)

        // A list client inside this real PTY is bound to the caller's pane through its controlling terminal.
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("akitty-agent").path
        let listOut = root.appendingPathComponent("inside-list"), listDone = root.appendingPathComponent("inside-list-done")
        try terminal.session.input("'\(cli)' --socket '\(path)' list > '\(listOut.path)'; : > '\(listDone.path)'\r", paste: false)
        try await waitUntil { FileManager.default.fileExists(atPath: listDone.path) }
        let listing = try JSONSerialization.jsonObject(with: Data(contentsOf: listOut)) as? [String: Any]
        let insideData = try XCTUnwrap(listing?["data"] as? [String: Any])
        XCTAssertEqual((insideData["source_pane"] as? String)?.hasSuffix("/\(terminal.session.id)"), true)
        let insidePane = try XCTUnwrap((insideData["panes"] as? [[String: Any]])?.first)
        XCTAssertEqual(insidePane["shell_ready"] as? Bool, false, "the listing command is still running when its reply is captured")
        let insideDirectory = insidePane["directory_untrusted"] as? String
        XCTAssertTrue(insideDirectory == root.path || insideDirectory == "/private" + root.path)
    }

    @MainActor func testDemoScriptUsesTheRealCompanionAndApprovalUI() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("isolated-shell")
        try "#!/bin/sh\nexec /bin/zsh -d -f -i\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        var preferences = TerminalPreferences(); preferences.shell = shell.path; preferences.directory = root.path; preferences.shellIntegration = false
        let terminal = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        window.orderFront(nil)
        let path = root.appendingPathComponent("requests.sock").path
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        service.cooldownInterval = 0; service.startRecording(); try service.setEnabled(true)
        defer { service.stop(); terminal.shutdown(); window.close() }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let integration = repository.appendingPathComponent("macos/Sources/AkittyKit/Resources/shell-integration/akitty.zsh")
        try terminal.session.input("AKITTY_FOLDER_HISTORY=0; source '\(integration.path)'\r")
        try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }
        let listing = try await Task.detached { try LocalSocket.request(Data("{\"version\":1,\"op\":\"list\"}".utf8), path: path) }.value
        let envelope = try JSONSerialization.jsonObject(with: listing) as! [String: Any]
        let pane = (((envelope["data"] as! [String: Any])["panes"] as! [[String: Any]])[0]["pane"] as! String)
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("akitty-agent")
        for approved in [false, true] {
            let expected = approved ? "approved" : "denied"
            let pending = Task.detached { () throws -> (Int32, Data) in
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [repository.appendingPathComponent("scripts/agent-demo.py").path, "--cli", cli.path,
                    "--socket", path, "--pane", pane, "--expect", expected, "--effect-timeout", "3"]
                process.standardOutput = output; process.standardError = Pipe()
                try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                return (process.terminationStatus, data)
            }
            try await waitUntil { window.attachedSheet != nil }
            window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: approved ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            let (status, data) = try await pending.value
            XCTAssertEqual(status, 0, String(decoding: data, as: UTF8.self))
            let report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(report["dispatch"] as? String, approved ? "queued" : "denied")
            XCTAssertEqual(report["effect"] as? String, approved ? "expected_marker_observed" : "not_observed")
            XCTAssertEqual(report["completion"] as? String, "unverified")
            XCTAssertEqual(try terminal.session.snapshot()?.control?.agent, approved)
            if approved { try terminal.session.reclaimControl() }
        }
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
        window.orderFront(nil)
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
        // The sheet and lease go away before the request finishes unwinding; wait for it before the next request.
        try await waitUntil { try window.attachedSheet == nil && terminal.session.snapshot()?.control?.agent == false && !service.hasActiveRequest }
        service.cooldownInterval = 60
        let pending = Task.detached { try LocalSocket.request(request, path: path) }
        try await waitUntil { window.attachedSheet != nil }
        try service.setEnabled(false)
        do {
            let reply = try JSONSerialization.jsonObject(with: try await pending.value) as! [String: Any]
            XCTAssertEqual(reply["ok"] as? Bool, false)
        } catch { XCTAssertTrue(error.localizedDescription.contains("Dispatch outcome may be unknown")) }
        // Disabling closes the socket, so the caller's reply can arrive before the request unwinds and arms the
        // cooldown. Wait for that before checking that the next request is delayed by it.
        try await waitUntil { try window.attachedSheet == nil && terminal.session.snapshot()?.control?.agent == false && !service.hasActiveRequest }
        try service.setEnabled(true)
        // The cooldown now delays the next sheet in this window instead of rejecting the request.
        let delayedData = try JSONSerialization.data(withJSONObject: ["version": 1, "op": "request", "pane": pane, "command": "echo no", "request_id": "cooldown-1"])
        let delayed = Task.detached { try LocalSocket.request(delayedData, path: path) }
        try await waitUntil { service.status(of: "cooldown-1")?["state"] as? String == "queued" }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(window.attachedSheet, "a queued request must not show a sheet during the window cooldown")
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human", "a queued request holds no input lease")
        try service.setEnabled(false)
        // Disabling closes the socket; the caller sees either a refusal or the closed connection.
        do {
            let reply = try JSONSerialization.jsonObject(with: try await delayed.value) as? [String: Any]
            XCTAssertEqual(reply?["ok"] as? Bool, false)
        } catch { XCTAssertTrue(error.localizedDescription.contains("Dispatch outcome may be unknown"), "\(error)") }
        try await waitUntil { service.status(of: "cooldown-1")?["state"] as? String == "cancelled" }
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
    }

    @MainActor func testRequestFailingBeforeTheSheetDoesNotArmTheCooldown() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal; window.orderFront(nil)
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        service.cooldownInterval = 60
        defer { service.stop(); terminal.shutdown(); window.close() }
        // No OSC 133;A prompt: the shell is busy, so the request fails before any approval sheet exists.
        do { _ = try await service.request("echo busy", in: terminal, origin: .siri); XCTFail("A busy shell must fail the request") }
        catch { XCTAssertTrue(error.localizedDescription.contains("integrated shell prompt")) }
        XCTAssertNil(window.attachedSheet)
        // The retry must reach the pre-sheet failure again, never the cooldown guard.
        do { _ = try await service.request("echo busy again", in: terminal, origin: .siri); XCTFail("A busy shell must keep failing") }
        catch { XCTAssertTrue(error.localizedDescription.contains("integrated shell prompt"), "an unseen sheet must not rate limit: \(error)") }
        // A sheet the human never saw must not arm the cooldown: the retry reaches the sheet, not "rate limited".
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        let pending = Task { try await service.request("echo retry", in: terminal, origin: .siri) }
        try await waitUntil { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        do { _ = try await pending.value; XCTFail("Denied request must fail") } catch {}
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
    }

    @MainActor func testHidingTheWindowUnderAnApprovalSheetFailsClosed() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal; window.orderFront(nil)
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); terminal.shutdown(); window.close() }
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        var settled = false
        let pending = Task { @MainActor () -> Error? in
            defer { settled = true }
            do { _ = try await service.request("echo hidden", in: terminal, origin: .siri); return nil } catch { return error }
        }
        try await waitUntil { window.attachedSheet != nil }
        XCTAssertTrue(window.isVisible)
        // The quick terminal hotkey hides the window; the request must fail closed, not wait for the 120 s timeout.
        window.orderOut(nil)
        try await waitUntil { settled }
        let settledError = await pending.value
        XCTAssertNotNil(settledError)
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

    @MainActor func testRecorderDrainsUnseenAuditOnStopWhileLocalRequestsRemainOff() throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")))
        defer { service.stop(); terminal.shutdown() }
        service.startRecording()
        terminal.applySnapshot(.success(try terminal.session.snapshot()))
        XCTAssertFalse(service.enabled)
        XCTAssertEqual(terminal.snapshot?.control?.audit_seq, 0)
        let lease = try terminal.session.acquireControl(actor: "test recorder")
        XCTAssertThrowsError(try terminal.session.input("blocked human input"))
        try terminal.session.releaseControl(lease)
        // The view still holds its caught-up, unleased snapshot. Stop must drain the core anyway.
        XCTAssertEqual(terminal.snapshot?.control?.audit_seq, 0)
        service.stop()
        let records = try service.store.export().split(separator: 10).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }
        let events = records.compactMap { $0["event"] as? String }
        XCTAssertTrue(events.contains("acquired")); XCTAssertTrue(events.contains("human_input_blocked"))
        XCTAssertTrue(events.contains("released"))
        XCTAssertFalse(String(decoding: try service.store.export(), as: UTF8.self).contains("blocked human input"))
    }

    @MainActor func testRecorderObservesProgramStatusWhenIdleAuditReadsAreSkipped() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")))
        defer { service.stop(); terminal.shutdown() }
        service.startRecording()
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7501;state=blocked:kind=permission:app=test\u{7}"])
        terminal.applySnapshot(.success(try terminal.session.snapshot()))
        XCTAssertFalse(service.enabled)
        XCTAssertEqual(terminal.snapshot?.control?.audit_seq, 0)
        try await waitUntil {
            let records = try service.store.export().split(separator: 10).map {
                try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
            }
            return records.contains {
                guard $0["event"] as? String == "program_status_observed",
                      let fields = $0["fields"] as? [String: Any], let counts = fields["state_counts"] as? [String: Int] else { return false }
                return counts["blocked"] == 1
            }
        }
    }

    func testIdleAuditReadIsSkippedOnlyForACaughtUpPaneWithNoLease() {
        XCTAssertTrue(AgentRequests.canSkipAuditRead(agent: false, auditSeq: 0, cursor: 0))
        XCTAssertTrue(AgentRequests.canSkipAuditRead(agent: false, auditSeq: 4, cursor: 4))
        XCTAssertFalse(AgentRequests.canSkipAuditRead(agent: false, auditSeq: 5, cursor: 4))
        XCTAssertFalse(AgentRequests.canSkipAuditRead(agent: true, auditSeq: 4, cursor: 4))
        XCTAssertFalse(AgentRequests.canSkipAuditRead(agent: nil, auditSeq: 0, cursor: 0))
        XCTAssertFalse(AgentRequests.canSkipAuditRead(agent: false, auditSeq: nil, cursor: 0))
    }

    // MARK: Per-pane approval queue

    @MainActor private func readyPane() throws -> TerminalView {
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        return terminal
    }
    @MainActor private func host(_ views: [TerminalView]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        for view in views { content.addSubview(view) }
        window.contentView = content; window.orderFront(nil)
        return window
    }
    @MainActor private func submit(_ service: AgentRequests, _ command: String, _ terminal: TerminalView, id: String) -> Task<Error?, Never> {
        Task { @MainActor in
            do { _ = try await service.request(command, in: terminal, origin: .siri, requestID: id); return nil } catch { return error }
        }
    }
    @MainActor private func state(_ service: AgentRequests, _ id: String) -> String? { service.status(of: id)?["state"] as? String }

    @MainActor func testPanesQueueIndependentlyInArrivalOrderAndOnlyTheHeadIsPresented() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try readyPane(), second = try readyPane()
        let one = host([first]), two = host([second])
        let service = AgentRequests(source: { [first, second] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); first.shutdown(); second.shutdown(); one.close(); two.close() }
        let a = submit(service, "echo a", first, id: "a")
        try await waitUntil { one.attachedSheet != nil }
        let b = submit(service, "echo b", first, id: "b")
        let c = submit(service, "echo c", second, id: "c")
        try await waitUntil { two.attachedSheet != nil && self.state(service, "b") == "queued" }
        XCTAssertEqual(state(service, "a"), "awaiting_approval")
        XCTAssertEqual(service.status(of: "b")?["queue_position"] as? Int, 1)
        XCTAssertEqual(service.pendingSummary(for: first.session.id)?.count, 2)
        XCTAssertEqual(service.pendingSummary(for: second.session.id)?.count, 1)
        XCTAssertEqual(try second.session.snapshot()?.control?.agent, true, "a presented request holds its pane's lease")
        // Reusing an ID never queues or presents again.
        do { _ = try await service.request("echo a", in: first, origin: .siri, requestID: "a"); XCTFail("duplicate ID must be refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already received"), "\(error)") }
        XCTAssertEqual(service.pendingSummary(for: first.session.id)?.count, 2)
        // Handle the later pane first: deny C while A keeps waiting.
        two.endSheet(try XCTUnwrap(two.attachedSheet), returnCode: .alertSecondButtonReturn)
        let cError = await c.value
        XCTAssertNotNil(cError)
        XCTAssertEqual(state(service, "c"), "denied")
        XCTAssertEqual(state(service, "a"), "awaiting_approval")
        XCTAssertEqual(try second.session.snapshot()?.control?.owner, "human")
        let sheetA = try XCTUnwrap(one.attachedSheet)
        one.endSheet(sheetA, returnCode: .alertSecondButtonReturn)
        _ = await a.value
        try await waitUntil { one.attachedSheet != nil && one.attachedSheet !== sheetA }
        XCTAssertEqual(state(service, "b"), "awaiting_approval")
        one.endSheet(try XCTUnwrap(one.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await b.value
        XCTAssertEqual(state(service, "b"), "denied")
        XCTAssertFalse(service.hasActiveRequest)
        XCTAssertNil(service.pendingSummary(for: first.session.id))
        XCTAssertEqual(try first.session.snapshot()?.control?.owner, "human")
        let events = String(decoding: try service.store.export(), as: UTF8.self)
        XCTAssertFalse(events.contains("echo a")); XCTAssertTrue(events.contains("\"request_id\":\"b\""))
        // An ID AkiTTY assigned cannot be taken over by a caller that reuses it.
        let assigned = Task { @MainActor () -> Error? in
            do { _ = try await service.request("echo assigned", in: second, origin: .siri); return nil } catch { return error }
        }
        try await waitUntil { two.attachedSheet != nil }
        two.endSheet(try XCTUnwrap(two.attachedSheet), returnCode: .alertSecondButtonReturn)
        let assignedError = await assigned.value
        let assignedID = try XCTUnwrap((assignedError as? AgentRequests.RequestFailure)?.requestID)
        do { _ = try await service.request("echo takeover", in: first, origin: .siri, requestID: assignedID); XCTFail("assigned ID must not be reused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already received"), "\(error)") }
        XCTAssertEqual(service.status(of: assignedID)?["pane"] as? String, service.status(of: "c")?["pane"] as? String)
        XCTAssertNil(one.attachedSheet)
    }

    @MainActor func testOneWindowShowsOneSheetAtATimeAcrossItsSplitPanes() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let left = try readyPane(), right = try readyPane()
        let window = host([left, right])
        let service = AgentRequests(source: { [left, right] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); left.shutdown(); right.shutdown(); window.close() }
        let l = submit(service, "echo left", left, id: "left")
        try await waitUntil { window.attachedSheet != nil }
        let r = submit(service, "echo right", right, id: "right")
        try await waitUntil { self.state(service, "right") == "queued" }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(state(service, "right"), "queued", "the second pane waits for the window's sheet")
        XCTAssertEqual(try right.session.snapshot()?.control?.owner, "human", "a waiting request holds no lease")
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        _ = await l.value
        try await waitUntil { window.attachedSheet != nil && window.attachedSheet !== sheet }
        XCTAssertEqual(state(service, "right"), "awaiting_approval")
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await r.value
        XCTAssertFalse(service.hasActiveRequest)
    }

    @MainActor func testQueueLimitsAndLifetimeCountFromEnqueue() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let pane = try readyPane()
        let window = host([pane])
        let service = AgentRequests(source: { [pane] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); pane.shutdown(); window.close() }
        var tasks: [Task<Error?, Never>] = []
        for index in 0..<AgentRequests.perPaneLimit { tasks.append(submit(service, "echo \(index)", pane, id: "q\(index)")) }
        try await waitUntil { service.pendingSummary(for: pane.session.id)?.count == AgentRequests.perPaneLimit }
        do { _ = try await service.request("echo over", in: pane, origin: .siri, requestID: "over"); XCTFail("ninth request must be refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already has \(AgentRequests.perPaneLimit)"), "\(error)") }
        XCTAssertNil(service.status(of: "over"), "a refused request is not recorded or queued")
        // Cancelling a waiting caller removes only its own entry.
        tasks[3].cancel()
        _ = await tasks[3].value
        try await waitUntil { self.state(service, "q3") == "cancelled" }
        XCTAssertEqual(service.pendingSummary(for: pane.session.id)?.count, AgentRequests.perPaneLimit - 1)
        service.stop()
        for task in tasks { _ = await task.value }
        XCTAssertFalse(service.hasActiveRequest)
        XCTAssertEqual(try pane.session.snapshot()?.control?.owner, "human")

        let pane2 = try readyPane(), window2 = host([pane2])
        let short = AgentRequests(source: { [pane2] }, store: AgentEventStore(directory: root.appendingPathComponent("events2")), path: root.appendingPathComponent("short.sock").path)
        short.cooldownInterval = 0; short.requestTimeout = 1.5; short.minimumReviewTime = 1
        defer { short.stop(); pane2.shutdown(); window2.close() }
        // Both enqueue together; the tail can never have the minimum review time left once the head's sheet ends.
        let head = submit(short, "echo head", pane2, id: "head")
        let tail = submit(short, "echo tail", pane2, id: "tail")
        try await waitUntil { window2.attachedSheet != nil }
        // Nobody answers the head; its sheet times out, and the tail's lifetime has already run out while queued.
        let headError = await head.value, tailError = await tail.value
        XCTAssertNotNil(headError)
        XCTAssertTrue(tailError?.localizedDescription.contains("expired while queued") == true, "\(String(describing: tailError))")
        XCTAssertEqual(state(short, "tail"), "expired")
        XCTAssertEqual(try pane2.session.snapshot()?.control?.owner, "human")
    }

    @MainActor func testSocketHoldsRequestsForTwoPanesAndReportsStatusByID() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try readyPane(), second = try readyPane()
        let one = host([first]), two = host([second])
        let path = root.appendingPathComponent("requests.sock").path
        let service = AgentRequests(source: { [first, second] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        service.cooldownInterval = 0; try service.setEnabled(true)
        defer { service.stop(); first.shutdown(); second.shutdown(); one.close(); two.close() }
        func send(_ request: [String: Any]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: request)
            let response = try await Task.detached { try LocalSocket.request(data, path: path) }.value
            return try JSONSerialization.jsonObject(with: response) as! [String: Any]
        }
        let panes = ((try await send(["version": 1, "op": "list"])["data"] as! [String: Any])["panes"] as! [[String: Any]]).map { $0["pane"] as! String }
        XCTAssertEqual(panes.count, 2)
        let p1 = Task { try await send(["version": 1, "op": "request", "pane": panes[0], "command": "echo one", "request_id": "s-1"]) }
        let p2 = Task { try await send(["version": 1, "op": "request", "pane": panes[1], "command": "echo two", "request_id": "s-2"]) }
        try await waitUntil { one.attachedSheet != nil && two.attachedSheet != nil }
        let status = try await send(["version": 1, "op": "status", "request_id": "s-2"])
        XCTAssertEqual(status["ok"] as? Bool, true)
        XCTAssertEqual((status["data"] as? [String: Any])?["state"] as? String, "awaiting_approval")
        XCTAssertEqual((status["data"] as? [String: Any])?["pane"] as? String, panes[1])
        for bad: [String: Any] in [["version": 1, "op": "status", "request_id": "nope"], ["version": 1, "op": "status", "request_id": "bad id"],
                                   ["version": 1, "op": "status"], ["version": 1, "op": "request", "pane": panes[0], "command": "pwd", "request_id": 4]] {
            let reply = try await send(bad); XCTAssertEqual(reply["ok"] as? Bool, false, "\(bad)")
        }
        one.endSheet(try XCTUnwrap(one.attachedSheet), returnCode: .alertSecondButtonReturn)
        two.endSheet(try XCTUnwrap(two.attachedSheet), returnCode: .alertSecondButtonReturn)
        let r1 = try await p1.value, r2 = try await p2.value
        XCTAssertEqual(r1["ok"] as? Bool, false); XCTAssertEqual(r1["request_id"] as? String, "s-1")
        XCTAssertEqual(r2["request_id"] as? String, "s-2")
        let resend = try await send(["version": 1, "op": "request", "pane": panes[0], "command": "echo one", "request_id": "s-1"])
        XCTAssertTrue((resend["error"] as? String)?.contains("already received") == true)
        XCTAssertNil(one.attachedSheet)
        let finished = try await send(["version": 1, "op": "status", "request_id": "s-1"])
        XCTAssertEqual((finished["data"] as? [String: Any])?["state"] as? String, "denied")
    }

    @MainActor func testCooldownDelaysOnlyItsOwnWindowAndThenPresents() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try readyPane(), second = try readyPane()
        let one = host([first]), two = host([second])
        let service = AgentRequests(source: { [first, second] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        service.cooldownInterval = 1
        defer { service.stop(); first.shutdown(); second.shutdown(); one.close(); two.close() }
        let a = submit(service, "echo a", first, id: "a")
        try await waitUntil { one.attachedSheet != nil }
        one.endSheet(try XCTUnwrap(one.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await a.value
        let b = submit(service, "echo b", first, id: "b"), c = submit(service, "echo c", second, id: "c")
        // The other window is not delayed by this window's cooldown.
        try await waitUntil { two.attachedSheet != nil }
        XCTAssertEqual(state(service, "b"), "queued")
        XCTAssertNil(one.attachedSheet)
        try await waitUntil { one.attachedSheet != nil }
        XCTAssertEqual(state(service, "b"), "awaiting_approval")
        one.endSheet(try XCTUnwrap(one.attachedSheet), returnCode: .alertSecondButtonReturn)
        two.endSheet(try XCTUnwrap(two.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await b.value; _ = await c.value
        XCTAssertFalse(service.hasActiveRequest)
    }

    @MainActor func testClosedPaneAndPreSheetFailureReleaseTheQueueAndWindow() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let left = try readyPane(), right = try readyPane()
        let window = host([left, right])
        var panes = [left, right]
        let service = AgentRequests(source: { panes }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); left.shutdown(); right.shutdown(); window.close() }
        let head = submit(service, "echo head", left, id: "head")
        try await waitUntil { window.attachedSheet != nil }
        let queued = submit(service, "echo queued", left, id: "queued")
        let other = submit(service, "echo other", right, id: "other")
        try await waitUntil { self.state(service, "queued") == "queued" && self.state(service, "other") == "queued" }
        // The right pane is closed while its request waits behind the window's sheet.
        panes = [left]; right.shutdown()
        let otherError = await other.value
        XCTAssertNotNil(otherError)
        XCTAssertEqual(state(service, "other"), "cancelled")
        // The left pane's shell is busy when its next request reaches the head: it fails without a sheet or a denial,
        // and the window is free again for the request after it.
        _ = try left.session.call("feed", ["text": "\u{1b}]133;C\u{7}"])
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await head.value
        let queuedError = await queued.value
        XCTAssertTrue(queuedError?.localizedDescription.contains("integrated shell prompt") == true, "\(String(describing: queuedError))")
        XCTAssertEqual(state(service, "queued"), "failed")
        _ = try left.session.call("feed", ["text": "\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}"])
        let next = submit(service, "echo next", left, id: "next")
        try await waitUntil { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await next.value
        XCTAssertEqual(state(service, "next"), "denied")
        XCTAssertFalse(service.hasActiveRequest)
        XCTAssertEqual(try left.session.snapshot()?.control?.owner, "human")
    }

    @MainActor func testNextRequestWaitsForReclaimAfterAnApprovedDispatch() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var preferences = TerminalPreferences(); preferences.shell = "/bin/zsh"; preferences.directory = root.path; preferences.shellIntegration = false
        let terminal = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal; window.orderFront(nil)
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("requests.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); terminal.shutdown(); window.close() }
        let integration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AkittyKit/Resources/shell-integration/akitty.zsh").path
        try terminal.session.input("AKITTY_FOLDER_HISTORY=0; source '\(integration)'\r", paste: false)
        try await waitUntil { try terminal.session.snapshot()?.shell?.ready == true }
        let marker = root.appendingPathComponent("first.txt")
        let first = Task { @MainActor in try await service.request("printf FIRST > '\(marker.path)'", in: terminal, origin: .siri, requestID: "first") }
        try await waitUntil { window.attachedSheet != nil }
        let second = submit(service, "echo second", terminal, id: "second")
        try await waitUntil { self.state(service, "second") == "queued" }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let receipt = try await first.value
        XCTAssertEqual(receipt["request_id"] as? String, "first")
        XCTAssertEqual(state(service, "first"), "dispatched")
        try await waitUntil { (try? String(contentsOf: marker, encoding: .utf8)) == "FIRST" }
        // The pane is still leased to the approved request: the next one waits instead of failing.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(state(service, "second"), "queued")
        XCTAssertNil(window.attachedSheet)
        try terminal.session.reclaimControl()
        try await waitUntil { window.attachedSheet != nil }
        XCTAssertEqual(state(service, "second"), "awaiting_approval")
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await second.value
        XCTAssertEqual(state(service, "second"), "denied")
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
    }
}
