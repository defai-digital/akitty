import XCTest
import AppKit
@testable import AkittyKit

final class SilentModeTests: XCTestCase {
    func testLegacyPreferencesKeepTheirValuesAndSilentModePersists() throws {
        let older = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"fontName":"Menlo","fontSize":18,"scrollback":1000}"#.utf8))
        XCTAssertFalse(older.silentMode)
        XCTAssertEqual(older.fontSize, 18)
        let suite = "akitty-silent-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = older; settings.silentMode = true
        try settings.save(to: defaults)
        XCTAssertEqual(TerminalPreferences.load(from: defaults), settings)
        var draft = PreferencesDraft(preferences: older, automaticChecks: false)
        draft.draft.silentMode = true
        XCTAssertTrue(draft.hasChanges)
    }

    @MainActor func testOpenTerminalMutesSoundsButKeepsBellAndErrorNotifications() throws {
        _ = NSApplication.shared
        let suite = "akitty-silent-live-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = TerminalPreferences(); settings.silentMode = true
        try settings.save(to: defaults)
        let terminal = try TerminalView(headless: true, forceSoftware: true, forceShaderFailure: false, initial: settings, defaults: defaults)
        defer { terminal.shutdown() }
        var sounds = 0, bells = 0, statuses: [String] = []
        terminal.playAlertSound = { sounds += 1 }
        terminal.onBell = { bells += 1 }
        terminal.onStatus = { statuses.append($0) }
        let size = terminal.cellSize
        func bell() throws {
            _ = try terminal.session.call("feed", ["text": "\u{7}"])
            terminal.applySnapshot(.success(try terminal.session.snapshot()))
        }
        try bell()
        terminal.applySnapshot(.failure(AkittyError.core("Visible test error")))
        XCTAssertEqual(sounds, 0)
        XCTAssertEqual(bells, 1)
        XCTAssertTrue(statuses.contains("Visible test error"))
        settings.silentMode = false; try settings.save(to: defaults)
        try bell()
        terminal.applySnapshot(.failure(AkittyError.core("Another visible test error")))
        XCTAssertEqual(sounds, 2, "turning Silent mode off applies immediately to the open pane")
        XCTAssertEqual(bells, 2)
        XCTAssertTrue(statuses.contains("Another visible test error"))
        XCTAssertEqual(terminal.cellSize, size)
    }
}
