import XCTest
import AppKit
@testable import AkittyKit

final class PreferencesTests: XCTestCase {
    @MainActor func testSettingsDirectoryCanBeSelectedClearedAndSavedWithKeyboard() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let app = AkittyApplication(); app.makeMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(string: FileManager.default.homeDirectoryForCurrentUser.path)
        field.frame = NSRect(x: 10, y: 30, width: 380, height: 24)
        window.contentView?.addSubview(field); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (field.stringValue as NSString).length))
        editor.deleteBackward(nil); window.makeFirstResponder(nil)
        XCTAssertEqual(field.stringValue, "")
        let suite = "akitty-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = TerminalPreferences(); preferences.directory = FileManager.default.homeDirectoryForCurrentUser.path
        try preferences.save(to: defaults)
        preferences.directory = field.stringValue; try preferences.save(to: defaults)
        XCTAssertEqual(TerminalPreferences.load(from: defaults).directory, "", "clearing restores the default directory after reload")
    }

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

    func testEncodingThenDecodingRoundTripsCJKFontAndChromePreference() throws {
        var preferences = TerminalPreferences()
        preferences.cjkFont = "PingFang SC"; preferences.programChrome = false
        let decoded = try JSONDecoder().decode(TerminalPreferences.self, from: try JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(decoded.cjkFont, "PingFang SC")
        XCTAssertFalse(decoded.programChrome)
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

    func testApplyStateTracksEditsAndSuccessfulSaves() {
        var state = PreferencesDraft(preferences: TerminalPreferences(), automaticChecks: false)
        XCTAssertFalse(state.hasChanges, "Apply starts disabled when the draft matches saved settings")

        state.draft.optionAsAlt = true
        XCTAssertTrue(state.hasChanges, "Editing a preference enables Apply")
        state.markSaved()
        XCTAssertFalse(state.hasChanges, "A successful save disables Apply")

        state.draft.optionAsAlt = false
        XCTAssertTrue(state.hasChanges, "The saved baseline advances to the latest successful save")
        state.markSaved()
        state.automaticChecks = true
        XCTAssertTrue(state.hasChanges, "Update preference changes are included in the dirty state")
        state.markSaved()
        XCTAssertFalse(state.hasChanges)

        state.draft.fontSize += 1
        XCTAssertTrue(state.hasChanges)
        state.draft = TerminalPreferences()
        XCTAssertFalse(state.hasChanges, "Reverting every edit disables Apply again")
    }
}
