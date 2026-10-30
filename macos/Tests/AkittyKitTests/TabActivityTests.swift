import XCTest
@testable import AkittyKit

/// Program chrome marks the tab whose program sent it, so parallel sessions can be told apart.
final class TabActivityTests: XCTestCase {
    private let frame0 = Data([0x10, 0x20, 0x30, 0xFF])
    private let frame1 = Data([0x40, 0x50, 0x60, 0xFF])

    @MainActor private func working(_ pane: TerminalPane, mark: Int = 1) throws {
        _ = try pane.terminal.session.call("chrome", [
            "status": ["text": "Working", "tone": "info"],
            "progress": "indeterminate",
            "mark": mark,
            "sprite": ["w": 1, "h": 1, "frames": [frame0.base64EncodedString(), frame1.base64EncodedString()]]
        ])
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

    @MainActor func testWorkingSpriteShowsOnItsOwnTabNotTheTitleBar() async throws {
        _ = NSApplication.shared
        // The window holds the app weakly; the update reminder needs it alive.
        let app = AkittyApplication()
        let controller = try TerminalWindow(app: app, headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        controller.reduceMotion = false
        let first = try XCTUnwrap(controller.panes.first)
        try controller.newTab()
        XCTAssertEqual(controller.tabChips.count, 2)
        // The background tab reports work; the selected one does not.
        try working(first)
        try await waitUntil(controller) { controller.tabChips[0].activity != .none }
        XCTAssertEqual(controller.tabChips[0].activity, .working(pixels: frame1, width: 1, height: 1))
        XCTAssertEqual(controller.tabChips[1].activity, .none)
        XCTAssertFalse(controller.tabChips[0].activityMark.isHidden)
        XCTAssertEqual(controller.tabChips[0].accessibilityLabel()?.hasSuffix(", working"), true)
        XCTAssertTrue(controller.window?.titlebarAccessoryViewControllers.isEmpty ?? false)
        controller.reduceMotion = true
        XCTAssertEqual(controller.tabChips[0].activity, .working(pixels: frame0, width: 1, height: 1))
        // The update reminder stays the only title-bar accessory.
        controller.refreshUpdateReminder("0.7.0")
        XCTAssertEqual(controller.window?.titlebarAccessoryViewControllers.map { $0.view.accessibilityIdentifier() }, ["update-reminder"])
        controller.refreshUpdateReminder(nil)
    }

    @MainActor func testWorkThatEndsOutOfViewKeepsADotUntilTheTabIsShown() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let first = try XCTUnwrap(controller.panes.first)
        try controller.newTab()
        try working(first)
        try await waitUntil(controller) { controller.tabChips[0].activity != .none }
        _ = try first.terminal.session.call("chrome", ["clear": true])
        try await waitUntil(controller) { controller.tabChips[0].activity == .finished }
        XCTAssertEqual(controller.tabChips[0].accessibilityLabel()?.hasSuffix(", finished"), true)
        // Showing the tab in the key window acknowledges it.
        controller.selectTab(at: 0)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(controller.tabChips[0].activity, .none)
        XCTAssertTrue(controller.tabChips[0].activityMark.isHidden)
    }

    @MainActor func testStatusWithoutProgressIsNotWork() async throws {
        _ = NSApplication.shared
        let controller = try TerminalWindow(app: AkittyApplication(), headless: true)
        defer { controller.panes.forEach { $0.terminal.shutdown() } }
        let pane = try XCTUnwrap(controller.panes.first)
        _ = try pane.terminal.session.call("chrome", ["status": ["text": "Ready", "tone": "info"]])
        try await waitUntil(controller) { pane.status.stringValue.contains("Ready") }
        XCTAssertEqual(controller.tabChips[0].activity, .none)
    }

    func testOnlyProgressOrTheBusyMarkCountsAsWork() throws {
        func document(_ json: String) throws -> ChromeDocument { try JSONDecoder().decode(ChromeDocument.self, from: Data(json.utf8)) }
        XCTAssertTrue(try document(#"{"progress":"indeterminate"}"#).isWorking)
        XCTAssertTrue(try document(#"{"progress":0.5}"#).isWorking)
        XCTAssertTrue(try document(#"{"mark":"busy"}"#).isWorking)
        XCTAssertFalse(try document(#"{"mark":"idle"}"#).isWorking)
        XCTAssertFalse(try document(#"{"status":{"text":"x","tone":"info"}}"#).isWorking)
    }

    func testPixelArtStaysCrispAndDetailedSpritesAreSmoothed() {
        XCTAssertEqual(TabActivityMark.interpolation(edge: 4, devicePixels: 28), NSImageInterpolation.none)
        XCTAssertEqual(TabActivityMark.interpolation(edge: 28, devicePixels: 28), NSImageInterpolation.none)
        XCTAssertEqual(TabActivityMark.interpolation(edge: 28, devicePixels: 14), .high)
        XCTAssertEqual(TabActivityMark.interpolation(edge: 16, devicePixels: 28), .high)
    }

    @MainActor func testSpriteAlphaIsStraightNotPremultiplied() throws {
        // Half-transparent pure blue: a premultiplied reading would treat 0xFF over 0x80 as out of range.
        let rep = try XCTUnwrap(TabActivityMark.bitmap(pixels: Data([0, 0, 0xFF, 0x80]), width: 1, height: 1))
        XCTAssertTrue(rep.bitmapFormat.contains(.alphaNonpremultiplied))
        let color = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
        XCTAssertEqual(color.blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(color.alphaComponent, 0x80 / 255, accuracy: 0.01)
    }
}
