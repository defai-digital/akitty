import XCTest
@testable import AkittyKit

final class PreferencesRecoveryTests: XCTestCase {
    func testDirectoryCannotBeSavedOrRestoredAsShell() throws {
        let suite = "akitty-shell-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var invalid = TerminalPreferences()
        invalid.shell = FileManager.default.temporaryDirectory.path
        invalid.fontSize = 18
        invalid.optionAsAlt = true
        XCTAssertThrowsError(try invalid.validated(), "directory search permission does not make a shell executable")
        defaults.set(try JSONEncoder().encode(invalid), forKey: "terminalPreferences")
        var expected = invalid; expected.shell = ""
        XCTAssertEqual(TerminalPreferences.load(from: defaults), expected)
    }

    func testInvalidNumericPreferenceResetsOnlyItsOwnField() throws {
        let suite = "akitty-preferences-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fallback = TerminalPreferences()
        var original = fallback
        original.fontSize = 18
        original.scrollback = 1234
        original.shell = "/bin/zsh"
        original.directory = FileManager.default.temporaryDirectory.path
        original.optionAsAlt = true
        original.programChrome = false

        for size in [8.0, 37.0] {
            var invalid = original; invalid.fontSize = size
            defaults.set(try JSONEncoder().encode(invalid), forKey: "terminalPreferences")
            var expected = original; expected.fontSize = fallback.fontSize
            XCTAssertEqual(TerminalPreferences.load(from: defaults), expected, "invalid font size \(size)")
        }
        for scrollback in [-1, 20001] {
            var invalid = original; invalid.scrollback = scrollback
            defaults.set(try JSONEncoder().encode(invalid), forKey: "terminalPreferences")
            var expected = original; expected.scrollback = fallback.scrollback
            XCTAssertEqual(TerminalPreferences.load(from: defaults), expected, "invalid scrollback \(scrollback)")
        }
    }
}
