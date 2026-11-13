import XCTest
import AppKit
@testable import AkittyKit

final class WindowLayoutTests: XCTestCase {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "akitty-window-layout-" + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func layout(named name: String, directory: String = "/tmp") -> WindowLayout {
        WindowLayout(name: name, windows: [
            WindowLayout.Window(frame: [10, 20, 900, 600], selectedTab: 0, tabs: [
                WindowLayout.Tab(panes: [WindowLayout.Pane(directory: directory)], fractions: [1])
            ])
        ])
    }

    func testLayoutRoundTripsThroughJSON() throws {
        let value = WindowLayout(name: "Work", windows: [
            WindowLayout.Window(frame: [120, 80, 900, 600], selectedTab: 1, tabs: [
                WindowLayout.Tab(panes: [WindowLayout.Pane(directory: "/tmp"), WindowLayout.Pane(directory: "/usr")], fractions: [0.65, 0.35]),
                WindowLayout.Tab(panes: [WindowLayout.Pane(directory: "")], fractions: [1])
            ])
        ])
        let decoded = try JSONDecoder().decode(WindowLayout.self, from: try JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }
    @MainActor func testSaveDialogLeavesSensitiveTextCaptureUnchecked() {
        _ = NSApplication.shared
        let (alert, field, history) = AkittyApplication.layoutSaveAlert(name: "Work")
        XCTAssertEqual(field.stringValue, "Work")
        XCTAssertEqual(history.title, "Include recent scrollback")
        XCTAssertEqual(history.state, .off)
        XCTAssertTrue(alert.informativeText.contains("sensitive output"))
        XCTAssertTrue((alert.accessoryView as? NSStackView)?.views.contains(history) == true)
    }

    func testStoredScrollbackIsBoundedAndCanBeRemovedWithoutDeletingLayout() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var value = layout(named: "Private")
        value.windows[0].tabs[0].panes = Array(repeating: WindowLayout.Pane(directory: "/tmp", scrollback: String(repeating: "中文 output" + String(repeating: "x", count: 140) + "\n", count: 1000)), count: 8)
        value.windows[0].tabs = Array(repeating: value.windows[0].tabs[0], count: 2)
        XCTAssertTrue(WindowLayoutStore.upsert(value, in: defaults))
        let stored = try XCTUnwrap(WindowLayoutStore.load(from: defaults).first)
        let panes = stored.windows.flatMap(\.tabs).flatMap(\.panes)
        XCTAssertLessThanOrEqual(panes.reduce(0) { $0 + ($1.scrollback?.utf8.count ?? 0) }, 128 * 1024)
        for text in panes.compactMap(\.scrollback) {
            XCTAssertLessThanOrEqual(text.utf8.count, 16384)
            XCTAssertLessThanOrEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 200)
        }
        try WindowLayoutStore.removeScrollback(named: "PRIVATE", from: defaults)
        let cleared = try XCTUnwrap(WindowLayoutStore.load(from: defaults).first)
        XCTAssertEqual(cleared.name, stored.name)
        XCTAssertEqual(cleared.windows[0].tabs.count, 2)
        XCTAssertTrue(cleared.windows.flatMap(\.tabs).flatMap(\.panes).allSatisfy { $0.scrollback == nil && $0.directory == "/tmp" })
        XCTAssertFalse(defaults.data(forKey: WindowLayoutStore.key).map { String(decoding: $0, as: UTF8.self).contains("中文 output") } ?? true)
        XCTAssertEqual(SavedLayoutText.bounded("a\u{1b}\u{7}\r\nb"), "a\nb")
        XCTAssertEqual(SavedLayoutText.bounded("中文🙂", maxBytes: 4), "🙂")
    }

    @MainActor func testOptionalHistoryCaptureRestoresTextInEachPaneBeforeFreshOutput() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let original = try TerminalWindow(app: app, headless: true)
        defer { original.panes.forEach { $0.terminal.shutdown() }; original.window?.close() }
        _ = try original.splitPane(containing: original.panes[0].terminal)
        try original.newTab()
        for (index, pane) in original.panes.enumerated() {
            _ = try pane.terminal.session.call("feed", ["text": "saved-output-\(index) 中文"])
        }
        XCTAssertTrue(original.captureLayout().tabs.flatMap(\.panes).allSatisfy { $0.scrollback == nil })
        XCTAssertTrue(try original.captureLayout(includeScrollback: false).tabs.flatMap(\.panes).allSatisfy { $0.scrollback == nil })
        let saved = try original.captureLayout(includeScrollback: true)
        XCTAssertEqual(saved.tabs.flatMap(\.panes).compactMap(\.scrollback).count, 3)
        try app.openLayout(WindowLayout(name: "History", windows: [saved]), headless: true)
        defer { for window in app.windows { window.panes.forEach { $0.terminal.shutdown() }; window.window?.close() } }
        let restored = try XCTUnwrap(app.windows.first)
        for (index, pane) in restored.panes.enumerated() {
            let session = pane.terminal.session
            _ = try session.call("feed", ["text": "fresh-output"])
            let text = try session.recentText()
            XCTAssertTrue(text.contains("saved-output-\(index) 中文"))
            XCTAssertTrue(text.contains("[End restored text - fresh session]"))
            XCTAssertLessThan(try XCTUnwrap(text.range(of: "saved-output")).lowerBound, try XCTUnwrap(text.range(of: "fresh-output")).lowerBound)
            let found = try JSONSerialization.jsonObject(with: session.call("find", ["text": "saved-output-\(index)"])) as? [String: Any]
            XCTAssertEqual(found?["found"] as? Bool, true)
        }
        try restored.newTab()
        XCTAssertFalse(try XCTUnwrap(restored.selectedPane).session.recentText().contains("saved-output"), "ordinary new tabs never inherit restored text")
    }

    func testDecodingToleratesMissingFields() throws {
        let decoded = try JSONDecoder().decode(WindowLayout.self, from: Data(#"{"windows":[{}]}"#.utf8))
        XCTAssertEqual(decoded.name, "")
        XCTAssertEqual(decoded.windows.count, 1)
        XCTAssertEqual(decoded.windows[0].frame, [])
        XCTAssertEqual(decoded.windows[0].selectedTab, 0)
        XCTAssertEqual(decoded.windows[0].tabs, [])
    }

    func testCorruptStoredDataLoadsAsNoLayouts() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: WindowLayoutStore.key)
        XCTAssertEqual(WindowLayoutStore.load(from: defaults), [])
        defaults.set(Data(#"{"not":"an array"}"#.utf8), forKey: WindowLayoutStore.key)
        XCTAssertEqual(WindowLayoutStore.load(from: defaults), [])
    }

    func testStoreEnforcesNamesLimitsAndTheOldestDroppedPolicy() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WindowLayoutStore.validatedName("  Team  "), "Team")
        XCTAssertNil(WindowLayoutStore.validatedName("   "))
        XCTAssertNil(WindowLayoutStore.validatedName(String(repeating: "x", count: WindowLayoutStore.maxNameLength + 1)))

        for number in 1...WindowLayoutStore.maxLayouts { WindowLayoutStore.upsert(layout(named: "Layout \(number)"), in: defaults) }
        XCTAssertEqual(WindowLayoutStore.load(from: defaults).count, WindowLayoutStore.maxLayouts)
        // Documented policy: a 21st layout drops the oldest instead of growing past the cap.
        WindowLayoutStore.upsert(layout(named: "Layout 21"), in: defaults)
        let stored = WindowLayoutStore.load(from: defaults)
        XCTAssertEqual(stored.count, WindowLayoutStore.maxLayouts)
        XCTAssertEqual(stored.first?.name, "Layout 2")
        XCTAssertEqual(stored.last?.name, "Layout 21")

        let huge = WindowLayout(name: "  Huge  ", windows: Array(repeating: WindowLayout.Window(frame: [0, 0, 100, 100], selectedTab: 99, tabs: Array(repeating: WindowLayout.Tab(
            panes: Array(repeating: WindowLayout.Pane(directory: "/tmp"), count: 10), fractions: [4, 6]), count: 20)), count: 10))
        WindowLayoutStore.upsert(huge, in: defaults)
        let clamped = try XCTUnwrap(WindowLayoutStore.load(from: defaults).first { $0.name == "Huge" })
        XCTAssertEqual(clamped.windows.count, WindowLayoutStore.maxWindows)
        XCTAssertEqual(clamped.windows[0].tabs.count, WindowLayoutStore.maxTabs)
        XCTAssertEqual(clamped.windows[0].tabs[0].panes.count, WindowLayoutStore.maxPanes)
        XCTAssertEqual(clamped.windows[0].selectedTab, WindowLayoutStore.maxTabs - 1)
        XCTAssertEqual(clamped.windows[0].tabs[0].fractions.count, WindowLayoutStore.maxPanes)
        XCTAssertEqual(clamped.windows[0].tabs[0].fractions.reduce(0, +), 1, accuracy: 0.0001)

        // save reports invalid input instead of silently truncating a caller's intent.
        XCTAssertThrowsError(try WindowLayoutStore.save([WindowLayout(name: "", windows: [])], to: defaults))
        XCTAssertThrowsError(try WindowLayoutStore.save(Array(repeating: layout(named: "Layout"), count: WindowLayoutStore.maxLayouts + 1), to: defaults))
    }

    func testUpsertReplacesNamesCaseInsensitivelyAndDeleteRemovesThem() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        WindowLayoutStore.upsert(layout(named: " Work ", directory: "/tmp"), in: defaults)
        WindowLayoutStore.upsert(layout(named: "wORK", directory: "/usr"), in: defaults)
        let stored = WindowLayoutStore.load(from: defaults)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].name, "wORK")
        XCTAssertEqual(stored[0].windows[0].tabs[0].panes[0].directory, "/usr")
        WindowLayoutStore.delete(named: "work", from: defaults)
        XCTAssertTrue(WindowLayoutStore.load(from: defaults).isEmpty)
    }

    @MainActor func testRestoredFrameKeepsTheWindowReachableAndAtMinimumSize() throws {
        let tiny = WindowLayoutGeometry.restoredFrame([0, 0, 10, 10])
        XCTAssertEqual(tiny.width, 400)
        XCTAssertEqual(tiny.height, 250)
        XCTAssertEqual(WindowLayoutGeometry.restoredFrame([]).width, 1000)
        XCTAssertEqual(WindowLayoutGeometry.restoredFrame([]).height, 650)
        let offscreen = WindowLayoutGeometry.restoredFrame([-100_000, -100_000, 400, 250])
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screens in this host")
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.intersects(offscreen) }, "an off-screen saved frame is moved onto a visible screen")
    }

    @MainActor func testCaptureAndRestoreRebuildTabsSplitsAndSelection() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let directory = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let original = try TerminalWindow(app: app, headless: true, directory: directory)
        defer {
            original.panes.forEach { $0.terminal.shutdown() }
            original.window?.close()
        }
        try original.newTab()
        original.perform(.split)
        original.selectTab(at: 0)
        let captured = original.captureLayout()
        XCTAssertEqual(captured.tabs.count, 2)
        XCTAssertEqual(captured.tabs.map(\.panes.count), [1, 2])
        XCTAssertEqual(captured.selectedTab, 0)
        XCTAssertEqual(captured.tabs[1].fractions.count, 2)
        XCTAssertEqual(captured.tabs[1].fractions.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertTrue(captured.tabs.flatMap(\.panes).allSatisfy { TerminalWindow.existingDirectory($0.directory) })

        try app.openLayout(WindowLayout(name: "Restore", windows: [captured]), headless: true)
        defer { for window in app.windows { window.panes.forEach { $0.terminal.shutdown() }; window.window?.close() } }
        let restored = try XCTUnwrap(app.windows.first)
        XCTAssertEqual(restored.tabs.numberOfTabViewItems, 2)
        let paneCounts = restored.tabs.tabViewItems.map { ($0.view as? NSSplitView)?.arrangedSubviews.count ?? 0 }
        XCTAssertEqual(paneCounts, [1, 2])
        XCTAssertTrue(restored.tabs.selectedTabViewItem === restored.tabs.tabViewItems[0])
    }

    @MainActor func testLayoutsSaveAndRestoreEachPaneProfile() throws {
        _ = NSApplication.shared
        let app = AkittyApplication(), work = UUID(), notes = UUID()
        let original = try TerminalWindow(app: app, headless: true, profile: work)
        defer { original.panes.forEach { $0.terminal.shutdown() }; original.window?.close() }
        _ = try original.splitPane(containing: original.panes[0].terminal)
        try original.newTab(profile: notes, copyDirectory: false)
        try original.newTab(profile: nil, copyDirectory: false)
        let captured = original.captureLayout()
        XCTAssertEqual(captured.tabs.map { $0.panes.map(\.profile) }, [[work, work], [notes], [nil]])
        // Older saved layouts have no profile field and restore with the defaults.
        let legacy = try JSONDecoder().decode(WindowLayout.Pane.self, from: Data(#"{"directory":"/tmp"}"#.utf8))
        XCTAssertNil(legacy.profile)
        try app.openLayout(WindowLayout(name: "Profiles", windows: [captured]), headless: true)
        defer { for window in app.windows { window.panes.forEach { $0.terminal.shutdown() }; window.window?.close() } }
        let restored = try XCTUnwrap(app.windows.first)
        let profiles = restored.tabs.tabViewItems.map { (($0.view as? NSSplitView)?.arrangedSubviews ?? []).compactMap { $0 as? TerminalPane } }
        XCTAssertEqual(profiles.map(\.count), [2, 1, 1])
        XCTAssertEqual(restored.panes.map(\.terminal.profileID), [work, work, notes, nil])
    }

    @MainActor func testRestoringAMissingDirectoryFallsBackWithoutThrowing() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let missing = "/does-not-exist/akitty-layout-" + UUID().uuidString
        let saved = WindowLayout(name: "Missing", windows: [
            WindowLayout.Window(frame: [0, 0, 500, 400], selectedTab: 0, tabs: [
                WindowLayout.Tab(panes: [WindowLayout.Pane(directory: missing), WindowLayout.Pane(directory: missing)], fractions: [0.5, 0.5])
            ])
        ])
        XCTAssertNoThrow(try app.openLayout(saved, headless: true))
        defer { for window in app.windows { window.panes.forEach { $0.terminal.shutdown() }; window.window?.close() } }
        let restored = try XCTUnwrap(app.windows.first)
        XCTAssertEqual(restored.panes.count, 2)
        XCTAssertEqual(restored.panes.map(\.launchDirectory), [nil, nil])
    }

    @MainActor func testCaptureKeepsEachPanesStartingFolderWithoutShellReports() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        let startingDirectory = TerminalPreferences.load().directory
        let expected = startingDirectory.isEmpty ? ProcessInfo.processInfo.environment["HOME"] ?? "/" : startingDirectory
        let windowDirectory = expected == "/usr" ? "/bin" : "/usr"
        let original = try TerminalWindow(app: app, headless: true, directory: windowDirectory)
        defer { original.panes.forEach { $0.terminal.shutdown() }; original.window?.close() }
        try original.newTab(profile: nil, copyDirectory: false)
        let captured = original.captureLayout()
        XCTAssertEqual(captured.tabs[0].panes[0].directory, windowDirectory)
        XCTAssertEqual(captured.tabs[1].panes[0].directory, expected,
                       "without OSC 7, a defaults tab must keep its own starting folder instead of the window's")
    }

    func testSplitSharesRemainNormalizedWhenTheirSumWouldOverflow() {
        let tab = WindowLayout.Tab(panes: [WindowLayout.Pane(), WindowLayout.Pane()],
                                   fractions: [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude / 2]).clamped()
        XCTAssertEqual(tab.fractions[0], 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(tab.fractions[1], 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(tab.fractions.reduce(0, +), 1, accuracy: 0.0001)
    }

    @MainActor func testRestoringTheNinthTabDoesNotSelectTheLastTab() throws {
        _ = NSApplication.shared
        let saved = WindowLayout.Window(selectedTab: 8, tabs: Array(repeating:
            WindowLayout.Tab(panes: [WindowLayout.Pane(directory: "/usr")], fractions: [1]), count: 10))
        let controller = try TerminalWindow.restored(app: AkittyApplication(), headless: true, layout: saved)
        defer { controller.panes.forEach { $0.terminal.shutdown() }; controller.window?.close() }
        XCTAssertEqual(controller.tabs.numberOfTabViewItems, 10)
        XCTAssertTrue(controller.tabs.selectedTabViewItem === controller.tabs.tabViewItems[8],
                      "a saved tab index is literal, while Command-9 remains the last-tab shortcut")
        controller.selectTab(at: 8)
        XCTAssertTrue(controller.tabs.selectedTabViewItem === controller.tabs.tabViewItems[9],
                      "the keyboard shortcut still selects the last tab")
    }

    @MainActor func testSavingWithoutARegularWindowReportsWhy() throws {
        _ = NSApplication.shared
        let app = AkittyApplication()
        XCTAssertThrowsError(try app.saveLayout(named: "Empty")) { error in
            XCTAssertEqual(error as? WindowLayoutError, .noWindows)
        }
    }
}
