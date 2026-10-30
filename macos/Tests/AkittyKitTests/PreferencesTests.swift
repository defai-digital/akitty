import XCTest
import AppKit
@testable import AkittyKit

final class PreferencesTests: XCTestCase {
    func testDecodingPreferencesSavedBeforeCJKFontExistedKeepsEveryValue() throws {
        let json = #"{"fontName":"Menlo","fontSize":14,"shell":"","directory":"","scrollback":5000,"optionAsAlt":false}"#
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.cjkFont, "", "a missing key means Automatic")
        XCTAssertEqual(preferences.fontName, "Menlo")
        XCTAssertEqual(preferences.fontSize, 14)
        XCTAssertEqual(preferences.shell, "")
        XCTAssertEqual(preferences.directory, "")
        XCTAssertEqual(preferences.scrollback, 5000)
        XCTAssertFalse(preferences.optionAsAlt)
    }

    func testEncodingThenDecodingRoundTripsCJKFont() throws {
        var preferences = TerminalPreferences()
        preferences.cjkFont = "PingFang SC"
        let decoded = try JSONDecoder().decode(TerminalPreferences.self, from: try JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(decoded.cjkFont, "PingFang SC")
    }

    @MainActor func testAvailableFontsStartsWithSystemMonospacedAndListsMenloOnce() {
        let fonts = TerminalPreferences.availableFonts()
        XCTAssertEqual(fonts.first, "System Monospaced")
        XCTAssertTrue(fonts.contains("Menlo"))
        XCTAssertEqual(fonts.count, Set(fonts).count, "family names are unique")
        XCTAssertFalse(fonts.contains(""))
    }

    func testValidatedAcceptsInstalledFontsAndRejectsUnknownNames() throws {
        var preferences = TerminalPreferences()
        XCTAssertNoThrow(try preferences.validated())
        preferences.fontName = "Menlo"
        XCTAssertNoThrow(try preferences.validated())
        preferences.fontName = "No Such Font 12345"
        XCTAssertThrowsError(try preferences.validated())
        preferences.fontName = "Menlo"; preferences.cjkFont = "No Such Font 12345"
        XCTAssertThrowsError(try preferences.validated())
        preferences.cjkFont = ""
        try XCTSkipUnless(NSFont(name: "PingFang SC", size: 12) != nil, "PingFang SC is not installed")
        preferences.cjkFont = "PingFang SC"
        XCTAssertNoThrow(try preferences.validated())
    }

    func testLoadingResetsOnlyBogusCJKFontAndKeepsOtherSavedValues() throws {
        let suite = "akitty-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = TerminalPreferences(); saved.fontSize = 18; saved.scrollback = 1500; saved.cjkFont = "No Such Font 12345"
        defaults.set(try JSONEncoder().encode(saved), forKey: "terminalPreferences")
        let loaded = TerminalPreferences.load(from: defaults)
        XCTAssertEqual(loaded.cjkFont, "")
        XCTAssertEqual(loaded.fontSize, 18)
        XCTAssertEqual(loaded.scrollback, 1500)
    }
    /// A family offered by the picker that fails validation would leave the user unable to save their own choice.
    @MainActor func testEveryListedFontFamilyPassesValidation() {
        for family in TerminalPreferences.availableFonts() {
            var preferences = TerminalPreferences(); preferences.fontName = family
            XCTAssertNoThrow(try preferences.validated(), family)
        }
    }
}
