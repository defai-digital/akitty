import XCTest
import AppKit
@testable import AkittyKit

final class GlobalFindTests: XCTestCase {
    @MainActor private func cleanUp(_ app: AkittyApplication) {
        app.globalFind?.window?.close()
        for controller in app.windows {
            controller.panes.forEach { $0.terminal.shutdown() }
            controller.window?.close()
        }
    }

    @MainActor private func feed(_ terminal: TerminalView, _ text: String) throws {
        _ = try terminal.session.call("feed", ["text": text])
        terminal.poll()
    }

    /// The issue's check: two tabs and another window, then the same hits after a move and a close.
    @MainActor func testMarkersAcrossTabsAndWindowsNavigateAfterMoveAndClose() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        defer { cleanUp(app) }
        let first = try app.createTerminalWindow(headless: true)
        let alpha = try XCTUnwrap(first.active)
        try feed(alpha, "\u{1b}]2;Alpha Pane\u{7}\u{1b}]7;file://localhost/tmp/alpha\u{7}MARKER-a\r\n")
        try first.newTab()
        let beta = try XCTUnwrap(first.active)
        try feed(beta, "\u{1b}]2;Beta Pane\u{7}\u{1b}]7;file://localhost/tmp/beta\u{7}MARKER-b\r\n")
        let second = try app.createTerminalWindow(headless: true)
        let gamma = try XCTUnwrap(second.active)
        try feed(gamma, "\u{1b}]2;Gamma Pane\u{7}\u{1b}]7;file://localhost/tmp/gamma\u{7}MARKER-c\r\n")

        app.perform(.findAll, in: first.window, sender: NSMenuItem())
        let finder = try XCTUnwrap(app.globalFind)
        XCTAssertEqual(finder.window?.title, "Find in All Terminals")
        XCTAssertTrue(finder.window?.isVisible == true)
        finder.anchor = first
        finder.scope = .all
        finder.searchNow("MARKER")
        XCTAssertEqual(finder.statusText, "3 matches")
        XCTAssertEqual(Set(finder.hits.map(\.sessionID)), Set([alpha.session.id, beta.session.id, gamma.session.id]))
        let grouped = finder.rowDescriptions.filter { $0.hasPrefix("header:") }
        XCTAssertGreaterThanOrEqual(grouped.count, 5, "window and tab headers around the three panes")
        let alphaHit = try XCTUnwrap(finder.hits.first { $0.sessionID == alpha.session.id })
        XCTAssertEqual(alphaHit.paneTitle, "Alpha Pane")
        XCTAssertEqual(alphaHit.folder, "/tmp/alpha")
        XCTAssertTrue(alphaHit.snippet.contains("MARKER-a"))

        finder.scope = .window
        finder.searchNow("MARKER")
        XCTAssertEqual(Set(finder.hits.map(\.sessionID)), Set([alpha.session.id, beta.session.id]))

        finder.scope = .all
        finder.searchNow("MARKER")
        for hit in finder.hits {
            XCTAssertEqual(finder.activate(hit), "")
            let located = try XCTUnwrap(app.windows.flatMap(\.panes).first { $0.terminal.session.id == hit.sessionID })
            XCTAssertTrue(located.window?.firstResponder === located.terminal)
            let cells = try XCTUnwrap(located.terminal.session.snapshot()).cells
            let active = cells.filter(\.activeSearch).map(\.text).joined()
            XCTAssertEqual(active, "MARKER")
            let others = app.windows.flatMap(\.panes).filter { $0.terminal.session.id != hit.sessionID }
            for other in others {
                let cells = try XCTUnwrap(other.terminal.session.snapshot()).cells
                XCTAssertTrue(cells.allSatisfy { !$0.search && !$0.activeSearch })
            }
        }

        let movedHit = try XCTUnwrap(finder.hits.first { $0.sessionID == alpha.session.id })
        let movedTab = try XCTUnwrap(first.tabs.tabViewItems.first { item in
            ((item.view as? NSSplitView)?.arrangedSubviews ?? []).contains { ($0 as? TerminalPane)?.terminal.session.id == alpha.session.id }
        })
        let moved = try XCTUnwrap(app.moveTabToNewWindow(movedTab, from: first))
        XCTAssertEqual(finder.activate(movedHit), "")
        XCTAssertTrue(moved.panes.contains { $0.terminal.session.id == alpha.session.id })
        XCTAssertTrue(moved.window?.firstResponder === alpha)
        XCTAssertEqual(try XCTUnwrap(alpha.session.snapshot()).cells.filter(\.activeSearch).map(\.text).joined(), "MARKER")

        second.window?.makeKeyAndOrderFront(nil)
        second.window?.makeFirstResponder(gamma)
        let survivor = second.window?.firstResponder
        first.perform(.closePane, target: beta)
        let sheet = try XCTUnwrap(first.window?.attachedSheet)
        first.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        for _ in 0..<50 where first.panes.contains(where: { $0.terminal.session.id == beta.session.id }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(first.panes.contains { $0.terminal.session.id == beta.session.id })
        let closedHit = try XCTUnwrap(finder.hits.first { $0.sessionID == beta.session.id })
        XCTAssertEqual(finder.activate(closedHit), "This pane is closed.")
        XCTAssertTrue(second.window?.firstResponder === survivor)
        XCTAssertFalse(second.window?.firstResponder === alpha)

        let forged = GlobalFindHit(
            sessionID: gamma.session.id, rowID: .max, generation: 0, col: 0, endCol: 6, query: "MARKER", snippet: "gone",
            windowID: ObjectIdentifier(second), tabID: ObjectIdentifier(second.tabs.tabViewItems[0]),
            windowTitle: "", tabTitle: "", paneTitle: "", folder: nil
        )
        let before = second.window?.firstResponder
        XCTAssertEqual(finder.activate(forged), "This match is no longer in the pane's scrollback.")
        XCTAssertTrue(second.window?.firstResponder === before)
    }

    @MainActor func testEmptyQueryAndCapStatus() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        defer { cleanUp(app) }
        let window = try app.createTerminalWindow(headless: true)
        let terminal = try XCTUnwrap(window.active)
        let finder = GlobalFindController(app: app)
        finder.anchor = window
        finder.searchNow("")
        XCTAssertEqual(finder.hits, [])
        XCTAssertEqual(finder.statusText, "")
        finder.searchNow("missing-marker")
        XCTAssertEqual(finder.statusText, "No matches")
        var lines = ""
        for index in 0..<40 { lines += "CAP-\(index)\r\n" }
        try feed(terminal, lines)
        finder.searchNow("CAP-")
        XCTAssertEqual(finder.hits.count, 32)
        XCTAssertTrue(finder.statusText.contains("More matches were not listed."))
    }

    @MainActor func testFullResultListOnlyReportsOverflowWhenAnotherMatchExists() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        defer { cleanUp(app) }
        let window = try app.createTerminalWindow(headless: true)
        for _ in 0..<4 {
            try feed(try XCTUnwrap(window.active), String(repeating: "LIMIT-HIT\r\n", count: 25))
            try window.newTab()
        }
        let extra = try XCTUnwrap(window.active)
        window.tabs.selectTabViewItem(at: 0)
        let finder = GlobalFindController(app: app)
        finder.anchor = window
        finder.searchNow("LIMIT-HIT")
        XCTAssertEqual(finder.hits.count, 100)
        XCTAssertEqual(finder.statusText, "100 matches")

        try feed(extra, "LIMIT-HIT\r\n")
        finder.searchNow("LIMIT-HIT")
        XCTAssertEqual(finder.hits.count, 100)
        XCTAssertEqual(finder.statusText, "Showing 100 matches. More matches were not listed.")
    }

    @MainActor func testReopeningWithAnExistingQueryYieldsBetweenHistoryChunks() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let finder = GlobalFindController(app: app)
        defer { finder.window?.close(); cleanUp(app) }
        let window = try app.createTerminalWindow(headless: true)
        let terminal = try XCTUnwrap(window.active)
        try feed(terminal, "REOPEN-MARKER\r\n" + String(repeating: "filler\r\n", count: 300))
        finder.searchNow("REOPEN-MARKER")
        XCTAssertEqual(finder.statusText, "1 match")

        finder.show(anchor: window)
        XCTAssertEqual(finder.statusText, "Searching…")
        for _ in 0..<100 where finder.statusText == "Searching…" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(finder.statusText, "1 match")
        XCTAssertEqual(finder.hits.first?.sessionID, terminal.session.id)
    }

    @MainActor func testSplitPaneActivationFocusesThatPane() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        defer { cleanUp(app) }
        let window = try app.createTerminalWindow(headless: true)
        let top = try XCTUnwrap(window.active)
        try feed(top, "MARKER-top\r\n")
        window.perform(.split)
        XCTAssertEqual(window.panes.count, 2)
        let bottom = window.panes[1].terminal
        try feed(bottom, "MARKER-bottom\r\n")
        let finder = GlobalFindController(app: app)
        finder.anchor = window
        finder.searchNow("MARKER")
        let hit = try XCTUnwrap(finder.hits.first { $0.sessionID == bottom.session.id })
        XCTAssertEqual(finder.activate(hit), "")
        XCTAssertTrue(window.window?.firstResponder === bottom)
        XCTAssertFalse(window.window?.firstResponder === top)
    }

    @MainActor func testMenuAndPaletteAdvertiseFindAll() {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let app = AkittyApplication()
        app.makeMenu()
        let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }
        let item = edit?.items.first { $0.title == "Find in All Terminals" }
        XCTAssertEqual(item?.keyEquivalent, "f")
        XCTAssertEqual(item?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(NativeCommand.findAll.rawValue, "find-all")
        XCTAssertEqual(NativeCommand.findAll.title, "Find in All Terminals")
    }
}
