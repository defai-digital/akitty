import XCTest
@testable import AkittyKit

/// A tab title has to stay readable while programs animate theirs: a tab names one pane, spinner frames are dropped,
/// and fast title changes are paced.
final class TabTitleTests: XCTestCase {
    func testSpinnerFramesAtEitherEndAreDropped() {
        XCTAssertEqual(TabTitle.stable("⠋ Inspect sglang | ax-engine"), "Inspect sglang | ax-engine")
        XCTAssertEqual(TabTitle.stable("⠙Inspect"), "Inspect")
        XCTAssertEqual(TabTitle.stable("✳ Claude Code"), "Claude Code")
        XCTAssertEqual(TabTitle.stable("✳\u{FE0F} Claude Code"), "Claude Code")
        XCTAssertEqual(TabTitle.stable("· Thinking"), "Thinking")
        XCTAssertEqual(TabTitle.stable("build ⠹"), "build")
        XCTAssertEqual(TabTitle.stable("🕐 deploy"), "deploy")
        XCTAssertEqual(TabTitle.stable("⠋"), "")
        // Inside the title a glyph is a separator, not a frame; titles without a spinner keep every character.
        XCTAssertEqual(TabTitle.stable("vim · project"), "vim · project")
        XCTAssertEqual(TabTitle.stable("a ⠋ b"), "a ⠋ b")
        XCTAssertEqual(TabTitle.stable("  ~/code  "), "  ~/code  ")
        XCTAssertEqual(TabTitle.stable("/usr/local"), "/usr/local")
        XCTAssertEqual(TabTitle.stable(""), "")
        // Every frame of a spinning title is the same title.
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"].map { TabTitle.stable("\($0) guide | ax-engine-sglang") }
        XCTAssertEqual(Set(frames), ["guide | ax-engine-sglang"])
    }

    func testTitlesShowAtOnceUntilTheyComeTooFast() {
        var schedule = PaneTitleSchedule()
        XCTAssertEqual(schedule.receive("a", now: 0), .shown)
        XCTAssertEqual(schedule.receive("a", now: 0.125), .unchanged)
        XCTAssertEqual(schedule.receive("b", now: 0.25), .shown, "two changes in a row show at once")
        XCTAssertEqual(schedule.receive("c", now: 0.5), .held(until: 1))
        XCTAssertEqual(schedule.receive("d", now: 0.75), .unchanged, "a later title replaces the waiting one")
        XCTAssertEqual(schedule.shown, "b"); XCTAssertEqual(schedule.pending, "d")
        XCTAssertTrue(schedule.flush(now: 1))
        XCTAssertEqual(schedule.shown, "d"); XCTAssertNil(schedule.pending); XCTAssertNil(schedule.pendingUntil)
        XCTAssertEqual(schedule.receive("e", now: 1.125), .held(until: 1.25))
        XCTAssertEqual(schedule.receive("d", now: 1.1875), .unchanged)
        XCTAssertFalse(schedule.flush(now: 1.25), "a title that returned to the shown one changes nothing")
        XCTAssertEqual(schedule.shown, "d")
        XCTAssertFalse(schedule.flush(now: 1.5), "nothing waits")
        XCTAssertEqual(schedule.receive("f", now: 3), .shown, "after a quiet second a change shows at once")
    }

    func testAStreamOfTitlesChangesTheTabAtMostTwiceASecond() {
        var schedule = PaneTitleSchedule(), shows: [Double] = [], due: Double?
        for frame in 0..<50 {
            let now = Double(frame) / 10
            if let at = due, now >= at { due = nil; if schedule.flush(now: now) { shows.append(now) } }
            switch schedule.receive("\(frame) files", now: now) {
            case .shown: shows.append(now)
            case let .held(until): due = until
            case .unchanged: break
            }
        }
        if let at = due, schedule.flush(now: at) { shows.append(at) }
        XCTAssertEqual(schedule.shown, "49 files", "the latest title is shown once the stream stops")
        for (index, time) in shows.enumerated() {
            XCTAssertLessThanOrEqual(shows[index...].prefix { $0 - time < PaneTitleSchedule.window - 1e-9 }.count, PaneTitleSchedule.burst)
        }
        XCTAssertLessThan(shows.count, 15)
    }

    @MainActor func testTheTabNamesItsFocusedPaneOnly() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let left = try XCTUnwrap(controller.panes.first)
        let rightTerminal = try controller.splitPane(containing: left.terminal)
        let right = try XCTUnwrap(controller.panes.first { $0.terminal === rightTerminal })
        controller.window?.makeFirstResponder(rightTerminal); controller.refreshPaneFocus()
        right.terminal.onTitle?("Create repository contributor guide | ax-engine-sglang")
        XCTAssertEqual(controller.tabs.tabViewItems[0].label, "Create repository contributor guide | ax-engine-sglang")
        // An agent in the other pane animating its title must not take the tab over, frame by frame.
        for frame in ["⠋", "⠙", "⠹"] { left.terminal.onTitle?("\(frame) Inspect sglang | ax-engine") }
        XCTAssertEqual(controller.tabs.tabViewItems[0].label, "Create repository contributor guide | ax-engine-sglang")
        XCTAssertEqual(controller.tabChips[0].label, "Create repository contributor guide | ax-engine-sglang")
        XCTAssertEqual(controller.window?.title, "Create repository contributor guide | ax-engine-sglang — AkiTTY")
        // The focused pane's own spinner frames do not rename the tab either.
        for frame in ["⠸", "⠼", "⠴", "⠦"] { right.terminal.onTitle?("\(frame) Create repository contributor guide | ax-engine-sglang") }
        XCTAssertEqual(controller.tabChips[0].label, "Create repository contributor guide | ax-engine-sglang")
        // Focus moves the title with it.
        controller.window?.makeFirstResponder(left.terminal); controller.refreshPaneFocus()
        XCTAssertEqual(controller.tabChips[0].label, "Inspect sglang | ax-engine")
        XCTAssertEqual(controller.tabChips[0].accessibilityLabel(), "Inspect sglang | ax-engine", "VoiceOver reads the new title")
        XCTAssertEqual(controller.window?.title, "Inspect sglang | ax-engine — AkiTTY")
    }

    @MainActor func testReturningToATabFocusesAndNamesThePaneLeftFocused() throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let left = try XCTUnwrap(controller.panes.first)
        let rightTerminal = try controller.splitPane(containing: left.terminal)
        let right = try XCTUnwrap(controller.panes.first { $0.terminal === rightTerminal })
        controller.window?.makeFirstResponder(rightTerminal); controller.refreshPaneFocus()
        left.terminal.onTitle?("left"); right.terminal.onTitle?("right")
        try controller.newTab()
        XCTAssertFalse(controller.window?.firstResponder === rightTerminal)
        XCTAssertEqual(controller.tabs.tabViewItems[0].label, "right", "a background tab keeps naming the pane it left focused")
        controller.selectTab(at: 0)
        XCTAssertTrue(controller.window?.firstResponder === rightTerminal, "returning to a tab must not redirect typing to its first split")
        XCTAssertEqual(controller.tabChips[0].label, "right")
        // The tab remembers whichever pane was focused last.
        controller.window?.makeFirstResponder(left.terminal); controller.refreshPaneFocus()
        controller.selectTab(at: 1); controller.selectTab(at: 0)
        XCTAssertTrue(controller.window?.firstResponder === left.terminal)
    }

    @MainActor func testAHeldTitleReachesTheTab() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let pane = try XCTUnwrap(controller.panes.first)
        // The shell's own titles would race the test's; send through the pane's callback alone.
        let send = try XCTUnwrap(pane.terminal.onTitle); pane.terminal.onTitle = nil
        for title in ["one", "two", "three", "four"] { send(title) }
        XCTAssertNotEqual(controller.tabChips[0].label, "four", "the third change within a second waits")
        let deadline = Date().addingTimeInterval(3)
        while controller.tabChips[0].label != "four", Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.tabChips[0].label, "four", "the latest held title shows when its turn comes")
        XCTAssertEqual(controller.window?.title, "four — AkiTTY")
    }
}
