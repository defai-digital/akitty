import XCTest
@testable import AkittyKit

/// A bell that rings while its tab is out of view marks the tab and prefixes its title until the tab is shown, as
/// Ghostty's bell title feature does. A bell the user can see only beeps.
final class TabBellTests: XCTestCase {
    @MainActor private func waitUntil(_ controller: TerminalWindow, timeout: TimeInterval = 3, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            controller.panes.forEach { $0.terminal.poll() }
            try await Task.sleep(nanoseconds: 20_000_000)
            if predicate() { return }
        }
        XCTFail("timed out")
    }

    func testBellPrefixesTheTitleAndTheWindowNamesTheApp() {
        XCTAssertEqual(TabTitle.label("vim", bell: false), "vim")
        XCTAssertEqual(TabTitle.label("vim", bell: true), "🔔 vim")
        XCTAssertEqual(TabTitle.window("vim", bell: false), "vim — Akitty")
        XCTAssertEqual(TabTitle.window("vim", bell: true), "🔔 vim — Akitty")
        XCTAssertEqual(TabTitle.window("Akitty", bell: false), "Akitty")
        XCTAssertEqual(TabTitle.window("Akitty", bell: true), "🔔 Akitty")
        XCTAssertEqual(TabActivity.bell.accessibilityName, "Bell")
        XCTAssertNil(TabActivity.none.accessibilityName)
    }

    @MainActor func testBellOutOfViewMarksTheTabUntilItIsShown() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let first = try XCTUnwrap(controller.panes.first)
        try controller.newTab()
        // The background tab names itself and rings; the selected tab does not.
        _ = try first.terminal.session.call("feed", ["text": "\u{1b}]2;build\u{07}\u{07}"])
        try await waitUntil(controller) { controller.tabChips[0].activity == .bell }
        XCTAssertEqual(controller.tabChips[0].label, "🔔 build")
        XCTAssertEqual(controller.tabs.tabViewItems[0].label, "build", "the tab item keeps the raw title")
        XCTAssertEqual(controller.tabChips[0].accessibilityLabel()?.hasSuffix(", bell"), true)
        XCTAssertFalse(controller.tabChips[0].activityMark.isHidden)
        XCTAssertEqual(controller.tabChips[1].activity, .none)
        XCTAssertEqual(controller.window?.title, "Akitty", "the window names the selected tab, which did not ring")
        // Selecting the tab renames the window at once; showing it in the key window acknowledges the bell.
        controller.selectTab(at: 0)
        XCTAssertEqual(controller.window?.title, "🔔 build — Akitty")
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(controller.tabChips[0].activity, .none)
        XCTAssertTrue(controller.tabChips[0].activityMark.isHidden)
        XCTAssertEqual(controller.tabChips[0].label, "build")
        XCTAssertEqual(controller.window?.title, "build — Akitty")
    }

    @MainActor func testBellOutranksWorkAndReturnsItWhenAcknowledged() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let first = try XCTUnwrap(controller.panes.first)
        try controller.newTab()
        _ = try first.terminal.session.call("chrome", ["status": ["text": "Working", "tone": "info"], "progress": "indeterminate"])
        try await waitUntil(controller) { controller.tabChips[0].activity == .working(pixels: nil, width: 0, height: 0) }
        _ = try first.terminal.session.call("feed", ["text": "\u{07}"])
        try await waitUntil(controller) { controller.tabChips[0].activity == .bell }
        controller.selectTab(at: 0)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(controller.tabChips[0].activity, .working(pixels: nil, width: 0, height: 0), "the sprite returns once the bell is seen")
    }

    @MainActor func testClearedTitleFallsBackToTheDefaultName() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let pane = try XCTUnwrap(controller.panes.first)
        _ = try pane.terminal.session.call("feed", ["text": "\u{1b}]2;AX-Code | ax-code\u{07}"])
        try await waitUntil(controller) { controller.tabChips[0].label == "AX-Code | ax-code" }
        XCTAssertEqual(controller.window?.title, "AX-Code | ax-code — Akitty")
        // A program that clears its title on exit leaves a named tab, not a blank one.
        _ = try pane.terminal.session.call("feed", ["text": "\u{1b}]2;\u{07}"])
        try await waitUntil(controller) { controller.tabChips[0].label == "Akitty" }
        XCTAssertEqual(controller.window?.title, "Akitty")
    }
}
