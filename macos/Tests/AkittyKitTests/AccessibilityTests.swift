import AppKit
import XCTest
@testable import AkittyKit

final class AccessibilityTests: XCTestCase {
    @MainActor func testPresentedApprovalKeepsDenyDefaultAndDenialReturnsHumanControl() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        let terminal = try XCTUnwrap(controller.panes.first?.terminal)
        let window = try XCTUnwrap(controller.window)
        defer { controller.panes.forEach { $0.terminal.shutdown() }; window.close() }
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        let approval = Task { try await terminal.runAgentCommand(actor: "test-agent", command: "printf 'approval test'") }
        for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(sheet.defaultButtonCell?.title, "Deny")
        XCTAssertEqual((sheet.firstResponder as? NSButton)?.title, "Deny")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        do { _ = try await approval.value; XCTFail("denial must not dispatch") }
        catch { XCTAssertTrue(error.localizedDescription.contains("denied")) }
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
        let audit = try JSONSerialization.jsonObject(with: terminal.session.controlAudit()) as! [String: Any]
        XCTAssertFalse((audit["events"] as! [[String: Any]]).contains { $0["event"] as? String == "dispatched" })
    }

    @MainActor private func waitForSnapshot(_ terminal: TerminalView, until predicate: (Snapshot) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            terminal.poll()
            try await Task.sleep(nanoseconds: 20_000_000)
            if let snapshot = terminal.snapshot, predicate(snapshot) { return }
        }
        XCTFail("accessible snapshot did not update")
    }

    @MainActor func testLineNavigationUsesUTF16AndRejectsInvalidRanges() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        _ = try terminal.session.call("feed", ["text": "\u{1b}[2J\u{1b}[H中文🙂e\u{301}\r\nsecond line"])
        try await waitForSnapshot(terminal) { $0.text.contains("second line") }
        let first = terminal.accessibilityRange(forLine: 0), second = terminal.accessibilityRange(forLine: 1)
        XCTAssertTrue(try XCTUnwrap(terminal.accessibilityString(for: first)).hasPrefix("中文🙂e\u{301}"))
        XCTAssertTrue(try XCTUnwrap(terminal.accessibilityString(for: second)).hasPrefix("second line"))
        XCTAssertEqual(second.location, first.length + 1)
        XCTAssertEqual(terminal.accessibilityLine(for: first.length), 0, "newline belongs to the preceding line")
        XCTAssertEqual(terminal.accessibilityLine(for: second.location), 1)
        XCTAssertEqual(terminal.accessibilityLine(for: terminal.accessibilityNumberOfCharacters()), terminal.snapshot!.lines.count - 1)
        for index in [-1, NSNotFound, terminal.accessibilityNumberOfCharacters() + 1] {
            XCTAssertEqual(terminal.accessibilityLine(for: index), NSNotFound)
        }
        for line in [-1, NSNotFound, terminal.snapshot!.lines.count] {
            XCTAssertEqual(terminal.accessibilityRange(forLine: line).location, NSNotFound)
        }
        XCTAssertNil(terminal.accessibilityString(for: NSRange(location: NSNotFound, length: 1)))
        XCTAssertEqual(terminal.accessibilityNumberOfCharacters(), terminal.snapshot!.text.utf16.count)
        XCTAssertEqual(terminal.accessibilityInsertionPointLineNumber(), 1)
    }

    @MainActor func testAnnouncementsDistinguishHostControlFromUnverifiedProgramReports() throws {
        let session = try TerminalSession(headless: true)
        defer { try? session.close() }
        let human = try XCTUnwrap(session.snapshot())
        _ = try session.acquireControl(actor: "coding-agent")
        let leased = try XCTUnwrap(session.snapshot())
        XCTAssertTrue(TerminalView.accessibilityAnnouncement(previous: human, next: leased)?.contains("controlled by coding-agent") == true)
        _ = try session.call("feed", ["text": "\u{1b}]771;{\"mark\":\"busy\"}\u{7}"])
        let busy = try XCTUnwrap(session.snapshot())
        XCTAssertNil(TerminalView.accessibilityAnnouncement(previous: leased, next: busy))
        _ = try session.call("feed", ["text": "arbitrary terminal output\r\n"])
        XCTAssertNil(TerminalView.accessibilityAnnouncement(previous: busy, next: try XCTUnwrap(session.snapshot())))
        _ = try session.call("feed", ["text": "\u{1b}]771;{\"mark\":\"idle\"}\u{7}"])
        let idle = try XCTUnwrap(session.snapshot())
        XCTAssertEqual(TerminalView.accessibilityAnnouncement(previous: busy, next: idle), "Program reports it is idle.")
        _ = try session.call("feed", ["text": "\u{1b}]771;{\"mark\":\"error\"}\u{7}"])
        let error = try XCTUnwrap(session.snapshot())
        XCTAssertEqual(TerminalView.accessibilityAnnouncement(previous: idle, next: error), "Program reports an error.")
        XCTAssertNil(TerminalView.accessibilityAnnouncement(previous: error, next: error))
        XCTAssertNil(TerminalView.accessibilityAnnouncement(previous: nil, next: error))
        try session.reclaimControl()
        XCTAssertTrue(TerminalView.accessibilityAnnouncement(previous: error, next: try XCTUnwrap(session.snapshot()))?.contains("have not been stopped") == true)
    }

    @MainActor func testApprovalShowsExactContextAndDefaultsToDeny() throws {
        _ = NSApplication.shared
        let request = AgentCommandRequest(sessionID: 7, actor: "coding-agent", command: "printf 'review me'", cwd: "/tmp")
        let alert = AgentCommandHost.approvalAlert(request)
        XCTAssertTrue(alert.messageText.contains(request.actor))
        XCTAssertTrue(alert.informativeText.contains(request.command))
        XCTAssertTrue(alert.informativeText.contains("Terminal 7"))
        XCTAssertTrue(alert.informativeText.contains("Directory reported by shell: /tmp"))
        XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[1].cell)
        XCTAssertTrue(alert.window.initialFirstResponder === alert.buttons[1])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
        XCTAssertTrue(alert.buttons[0].accessibilityHelp()?.contains("exact command once") == true)
    }
}
