import XCTest
import AppKit
@testable import AkittyKit

final class AgentWorkflowTests: XCTestCase {
    func testPreparingDeferredCloseRevokesAccessBeforeCleanupRuns() throws {
        let session = try TerminalSession(headless:true)
        let cleanup = try XCTUnwrap(session.prepareClose())
        XCTAssertThrowsError(try session.snapshot())
        XCTAssertNil(session.prepareClose())
        // The worker has not run: prove cleanup ownership was transferred, not discarded.
        XCTAssertNoThrow(try CoreBridge.call(["op":"snapshot", "id":session.id]))
        try cleanup()
        XCTAssertThrowsError(try CoreBridge.call(["op":"snapshot", "id":session.id]))
    }

    @MainActor func testDeniedCommandWritesNothingAndReturnsHumanControl() async throws {
        let session = try TerminalSession(headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        let host = AgentCommandHost(session: session)
        do {
            _ = try await host.execute(actor: "test-agent", command: "echo hello") { request in
                XCTAssertEqual(request.cwd, "/tmp"); XCTAssertEqual(request.command, "echo hello"); return false
            }
            XCTFail("denial must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("denied")) }
        XCTAssertEqual(try session.snapshot()?.control?.owner, "human")
        let audit = try JSONSerialization.jsonObject(with: session.controlAudit()) as! [String:Any]
        let events = audit["events"] as! [[String:Any]]
        XCTAssertTrue(events.contains { $0["event"] as? String == "denied" })
        XCTAssertFalse(events.contains { $0["event"] as? String == "dispatched" })
    }

    @MainActor func testDirectoryChangeDuringApprovalDoesNotAuthorizeNewContext() async throws {
        let session = try TerminalSession(headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        do {
            _ = try await AgentCommandHost(session: session).execute(actor: "agent", command: "echo hi") { _ in
                _ = try session.call("feed", ["text": "\u{1b}]7;file:///elsewhere\u{7}"]); return true
            }
            XCTFail("changed directory must invalidate approval")
        } catch { XCTAssertTrue(error.localizedDescription.contains("working directory changed")) }
        XCTAssertEqual(try session.snapshot()?.control?.owner,"human")
    }

    @MainActor func testQuickTerminalTogglesKeepSessionAndRestoreFocus() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let controller = QuickTerminalController { try TerminalWindow(app: app, headless: true) }
        var restored = 0
        controller.restoreFocus = { restored += 1 }
        defer {
            controller.stop()
            controller.terminalWindow?.panes.forEach { $0.terminal.shutdown() }
            controller.terminalWindow?.window?.close()
        }
        try controller.toggle()
        let id = try XCTUnwrap(controller.terminalWindow?.active?.session.id)
        for _ in 0..<50 {
            try controller.toggle()
            XCTAssertFalse(controller.terminalWindow?.window?.isVisible ?? true)
            try controller.toggle()
            XCTAssertEqual(controller.terminalWindow?.active?.session.id,id)
        }
        XCTAssertEqual(restored,50)
        let window = try XCTUnwrap(controller.terminalWindow?.window)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(controller.terminalWindow?.active?.session.id,id)
    }

    @MainActor func testQuitFromHiddenQuickTerminalShowsConfirmationAndCancelKeepsSession() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let controller = QuickTerminalController { try TerminalWindow(app: app, headless: true) }
        controller.restoreFocus = {}
        try controller.toggle(); controller.hide()
        let window = try XCTUnwrap(controller.terminalWindow?.window)
        let terminals = try XCTUnwrap(controller.terminalWindow).panes.map(\.terminal)
        defer { terminals.forEach { $0.shutdown() }; window.close() }
        XCTAssertFalse(window.isVisible)
        var reply: Bool?
        XCTAssertEqual(app.requestTermination(terminals: terminals, window: window) { reply = $0 }, .terminateLater)
        XCTAssertTrue(window.isVisible)
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        for _ in 0..<50 where reply == nil { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(reply,false)
        XCTAssertNoThrow(try terminals[0].session.snapshot())
    }

    @MainActor func testShortcutConflictKeepsExistingRegistrationAndCanBeReleased() throws {
        _ = NSApplication.shared
        let first = GlobalShortcut(), second = GlobalShortcut()
        defer { first.stop(); second.stop() }
        try first.configure(enabled:true,choice:1)
        try first.configure(enabled:true,choice:0)
        XCTAssertThrowsError(try second.configure(enabled:true,choice:0))
        first.stop()
        XCTAssertNoThrow(try second.configure(enabled:true,choice:0))
        XCTAssertNoThrow(try second.configure(enabled:false,choice:0))
    }
}
