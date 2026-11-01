import XCTest
import AppKit
@testable import AkittyKit

/// The overview shows host control apart from what programs and shells report, and never reads terminal text.
final class AgentOverviewTests: XCTestCase {
    @MainActor func testReturnBelongsToTableAndWindowCloseStopsRefreshTimer() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() }; controller.window?.close() }
        var shown = 0
        let overview = AgentOverviewController(source: { [controller] }) { _, _ in shown += 1 }
        defer { overview.close() }
        overview.showWindow(nil)
        overview.select(sessionID: controller.panes[0].terminal.session.id)
        XCTAssertEqual(overview.showButton.keyEquivalent, "", "Return must not override another focused action")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: overview.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        overview.table.keyDown(with: event)
        XCTAssertEqual(shown, 1)
        XCTAssertTrue(overview.refreshTimerActive)
        overview.window?.performClose(nil)
        XCTAssertFalse(overview.refreshTimerActive)
        overview.showWindow(nil)
        XCTAssertTrue(overview.refreshTimerActive)
    }

    @MainActor func testRefreshPreservesAccessibleCellsAndRemovedSelectionDoesNotRetargetActions() async throws {
        _ = NSApplication.shared
        let first = try TerminalWindow(app: AkittyApplication(), headless: true)
        let second = try TerminalWindow(app: AkittyApplication(), headless: true)
        var windows = [first, second]
        defer { [first, second].forEach { $0.panes.forEach { $0.terminal.shutdown() }; $0.window?.close() } }
        let terminal = try XCTUnwrap(first.panes.first?.terminal)
        try await waitUntil(first) { terminal.snapshot != nil }
        let overview = AgentOverviewController(source: { windows }) { _, _ in }
        defer { overview.close() }
        overview.showWindow(nil)
        overview.select(sessionID: terminal.session.id)
        XCTAssertTrue(overview.window?.firstResponder === overview.table)
        let cell = try XCTUnwrap(overview.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
        _ = try terminal.session.acquireControl(actor: "review-agent")
        try await waitUntil(first) { terminal.snapshot?.control?.agent == true }
        overview.refresh()
        XCTAssertTrue(cell === overview.table.view(atColumn: 1, row: 0, makeIfNecessary: true))
        XCTAssertEqual(cell.accessibilityLabel(), "Control (host): Agent: review-agent")
        XCTAssertTrue(overview.reclaimButton.isEnabled)
        XCTAssertEqual(overview.table.selectedRow, 0)
        windows = [second]
        overview.refresh()
        XCTAssertEqual(overview.table.selectedRow, -1)
        XCTAssertFalse(overview.showButton.isEnabled)
        XCTAssertFalse(overview.reclaimButton.isEnabled)
    }

    @MainActor func testOverviewIncludesSplitPanesOtherWindowsAndHiddenQuickTerminal() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let first = try TerminalWindow(app: app, headless: true)
        let second = try TerminalWindow(app: app, headless: true)
        var windows = [first, second]
        let quick = QuickTerminalController {
            let window = try TerminalWindow(app: app, headless: true)
            windows.append(window); return window
        }
        quick.restoreFocus = {}
        defer { quick.stop(); windows.forEach { $0.panes.forEach { $0.terminal.shutdown() }; $0.window?.close() } }
        first.perform(.split)
        XCTAssertEqual(first.panes.count, 2)
        try quick.toggle(); quick.hide()
        let quickID = try XCTUnwrap(quick.terminalWindow?.active?.session.id)
        let overview = AgentOverviewController(source: { windows }) { _, _ in }
        defer { overview.close() }
        XCTAssertEqual(overview.entries.count, 4)
        XCTAssertTrue(overview.entries.contains { $0.row.sessionID == quickID })
        overview.select(sessionID: quickID)
        XCTAssertTrue(overview.showButton.isEnabled)
        XCTAssertTrue(overview.table.nextKeyView === overview.showButton)
        XCTAssertTrue(overview.showButton.nextKeyView === overview.reclaimButton)
        XCTAssertTrue(overview.reclaimButton.accessibilityHelp()?.contains("Does not stop") == true)
    }

    func testRowsKeepHostControlApartFromProgramReports() throws {
        let session = try TerminalSession(headless: true)
        defer { try? session.close() }
        let idle = AgentOverviewRow(sessionID: session.id, snapshot: try session.snapshot())
        XCTAssertEqual(idle.controller, "Human")
        XCTAssertFalse(idle.agentControlled)
        XCTAssertNil(idle.programStatus)
        XCTAssertEqual(idle.state, "Running")

        let lease = try session.acquireControl(actor: "test-agent")
        // A program forges a status naming another controller, and plain output imitates one.
        _ = try session.call("feed", ["text": "\u{1b}]771;{\"status\":{\"text\":\"Controlled by impostor\",\"tone\":\"info\"},\"mark\":\"busy\"}\u{7}\u{1b}]7;file:///tmp\u{7}Agent: evil\r\n"])
        let leased = AgentOverviewRow(sessionID: session.id, snapshot: try session.snapshot())
        XCTAssertEqual(leased.controller, "Agent: test-agent")
        XCTAssertTrue(leased.agentControlled)
        XCTAssertEqual(leased.programStatus, "busy · Controlled by impostor")
        XCTAssertEqual(leased.shellDirectory, "/tmp")

        try session.releaseControl(lease)
        XCTAssertEqual(AgentOverviewRow(sessionID: session.id, snapshot: try session.snapshot()).controller, "Human")
    }

    func testTerminalTextAloneChangesNothing() throws {
        let session = try TerminalSession(headless: true)
        defer { try? session.close() }
        let before = AgentOverviewRow(sessionID: session.id, snapshot: try session.snapshot())
        _ = try session.call("feed", ["text": "Controlled by agent · busy 50%\r\n/tmp\r\n"])
        let after = AgentOverviewRow(sessionID: session.id, snapshot: try session.snapshot())
        XCTAssertEqual(after.controller, before.controller)
        XCTAssertEqual(after.programStatus, before.programStatus)
        XCTAssertEqual(after.shellDirectory, before.shellDirectory)
    }

    @MainActor private func waitUntil(_ controller: TerminalWindow, timeout: TimeInterval = 3, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            controller.panes.forEach { $0.terminal.poll() }
            try await Task.sleep(nanoseconds: 20_000_000)
            if predicate() { return }
        }
        XCTFail("timed out")
    }

    @MainActor func testPaletteCommandAndMenuOpenTheOverview() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let controller = try TerminalWindow(app: app, headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() }; app.agentOverview?.close() }
        XCTAssertNil(app.agentOverview)
        controller.perform(.agentOverview)
        let overview = try XCTUnwrap(app.agentOverview)
        XCTAssertTrue(overview.window?.isVisible == true)
        controller.perform(.agentOverview)
        XCTAssertTrue(app.agentOverview === overview, "reopening reuses the one overview window")
        app.makeMenu()
        let item = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Window" }?.items.first { $0.title == "Agent Overview" }
        XCTAssertEqual(item?.keyEquivalent, "a")
        XCTAssertEqual(item?.keyEquivalentModifierMask, [.command, .option])
    }

    @MainActor func testCommandWClosesOverviewWithoutClosingTerminal() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let terminal = try TerminalWindow(app: app, headless: true)
        defer { terminal.panes.forEach { $0.terminal.shutdown() }; app.agentOverview?.close() }
        app.showAgentOverview(nil)
        let window = try XCTUnwrap(app.agentOverview?.window)
        XCTAssertTrue(window.isVisible)
        app.perform(.closePane, in: window, sender: NSMenuItem())
        XCTAssertFalse(window.isVisible, "Command-W closes the focused utility window")
        XCTAssertEqual(terminal.panes.count, 1)
        XCTAssertNotNil(try terminal.panes[0].terminal.session.snapshot())
    }

    @MainActor func testOverviewListsEveryPaneShowsAndReclaims() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let first = try XCTUnwrap(controller.panes.first?.terminal)
        try controller.newTab()
        XCTAssertEqual(controller.panes.count, 2)
        _ = try first.session.acquireControl(actor: "test-agent")
        try await waitUntil(controller) { first.snapshot?.control?.agent == true }

        var shown: [UInt64] = []
        let overview = AgentOverviewController(source: { [controller] }) { window, terminal in shown.append(terminal.session.id); window.focus(terminal) }
        defer { overview.close() }
        XCTAssertEqual(overview.entries.map(\.row.sessionID), controller.panes.map(\.terminal.session.id))
        XCTAssertEqual(overview.table.numberOfRows, 2)
        XCTAssertFalse(overview.showButton.isEnabled)

        // The human pane offers no reclaim.
        overview.select(sessionID: controller.panes[1].terminal.session.id)
        XCTAssertTrue(overview.showButton.isEnabled)
        XCTAssertFalse(overview.reclaimButton.isEnabled)

        overview.select(sessionID: first.session.id)
        XCTAssertTrue(overview.reclaimButton.isEnabled)
        overview.showSelected(nil)
        XCTAssertEqual(shown, [first.session.id])
        XCTAssertTrue((controller.tabs.selectedTabViewItem?.view as? NSSplitView)?.arrangedSubviews.contains { ($0 as? TerminalPane)?.terminal === first } == true)

        overview.reclaimSelected(nil)
        try await waitUntil(controller) { first.snapshot?.control?.agent == false }
        overview.refresh()
        XCTAssertEqual(overview.entries.first?.row.controller, "Human")
        XCTAssertFalse(overview.reclaimButton.isEnabled)
        let audit = try JSONSerialization.jsonObject(with: first.session.controlAudit()) as! [String: Any]
        XCTAssertTrue((audit["events"] as! [[String: Any]]).contains { $0["event"] as? String == "human_reclaimed" })
    }
}
