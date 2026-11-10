import XCTest
import AppKit
import Darwin
@testable import AkittyKit

final class PreferencesTests: XCTestCase {
    func testPasteConfirmationDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8)).confirmPaste)
        var preferences = TerminalPreferences(); preferences.confirmPaste = false
        XCTAssertFalse(try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(preferences)).confirmPaste)
    }
    func testClipboardWriteConfirmationDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8)).confirmClipboardWrite)
        var preferences = TerminalPreferences(); preferences.confirmClipboardWrite = false
        XCTAssertFalse(try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(preferences)).confirmClipboardWrite)
        var state = PreferencesDraft(preferences: TerminalPreferences(), automaticChecks: false)
        state.mergeClipboardWriteConfirmation(false)
        XCTAssertFalse(state.draft.confirmClipboardWrite)
        XCTAssertFalse(state.hasChanges)
    }
    func testExternalPasteChoiceRefreshesSettingsWithoutDiscardingDraftEdits() {
        var state = PreferencesDraft(preferences: TerminalPreferences(), automaticChecks: false)
        state.draft.fontSize = 18
        state.mergePasteConfirmation(false)
        XCTAssertFalse(state.draft.confirmPaste)
        XCTAssertFalse(state.saved.confirmPaste)
        XCTAssertEqual(state.draft.fontSize, 18)
        XCTAssertTrue(state.hasChanges)
        state.draft.confirmPaste = true
        state.mergePasteConfirmation(false)
        XCTAssertTrue(state.draft.confirmPaste, "an explicit unsaved Settings choice is preserved")
        XCTAssertFalse(state.saved.confirmPaste)
    }
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

    func testShellIntegrationIsOnByDefaultAndKeepsASavedChoice() throws {
        XCTAssertTrue(TerminalPreferences().shellIntegration)
        let older = #"{"fontName":"Menlo","fontSize":14,"shell":"","directory":"","scrollback":5000,"optionAsAlt":false}"#
        XCTAssertTrue(try JSONDecoder().decode(TerminalPreferences.self, from: Data(older.utf8)).shellIntegration, "a missing key takes the default")
        let savedOff = #"{"fontName":"Menlo","fontSize":14,"shell":"","directory":"","scrollback":5000,"optionAsAlt":false,"shellIntegration":false}"#
        XCTAssertTrue(try JSONDecoder().decode(TerminalPreferences.self, from: Data(savedOff.utf8)).shellIntegration,
                      "saves from before the default changed held the old default, so they move to on once")
        var off = TerminalPreferences(); off.shellIntegration = false
        XCTAssertFalse(try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(off)).shellIntegration,
                       "turning it off after the change is kept")
        let suite = "akitty-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try off.save(to: defaults)
        XCTAssertFalse(TerminalPreferences.load(from: defaults).shellIntegration)
    }

    func testFolderHistoryIsOnByDefaultKeepsAChoiceAndClears() throws {
        XCTAssertTrue(TerminalPreferences().folderHistory)
        let older = #"{"fontName":"Menlo","fontSize":14,"shell":"","directory":"","scrollback":5000,"optionAsAlt":false}"#
        XCTAssertTrue(try JSONDecoder().decode(TerminalPreferences.self, from: Data(older.utf8)).folderHistory, "a missing key takes the default")
        var off = TerminalPreferences(); off.folderHistory = false
        XCTAssertFalse(try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(off)).folderHistory)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-folder-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("1\t/tmp\t/private/tmp\tmake release\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(atPath: file.path + ".lock") }
        try TerminalPreferences.clearFolderHistory(file: file)
        XCTAssertEqual(try Data(contentsOf: file).count, 0, "clearing empties the file in place")
        try TerminalPreferences.clearFolderHistory(file: file.appendingPathExtension("missing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("missing").path), "clearing never creates the file")
    }

    func testClearFolderHistoryRefusesSymlinksAndPreservesTheirTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-folder-safe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("history")
        try Data("keep this".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try TerminalPreferences.clearFolderHistory(file: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep this")
    }

    func testClearFolderHistoryHonorsTheShellsPOSIXLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-folder-lock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history"), lock = root.appendingPathComponent("history.lock")
        try Data("keep".utf8).write(to: file); try Data().write(to: lock)
        for path in [file, lock] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", "zmodload zsh/system; zsystem flock -f held \"$1\" || exit 1; print READY; read -r done", "--", lock.path]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 6), Data("READY\n".utf8))
        XCTAssertThrowsError(try TerminalPreferences.clearFolderHistory(file: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
    }

    func testIntegrationDirectoryOnlyForBundledBashAndZsh() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-integration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: resources) }
        let directory = resources.appendingPathComponent("shell-integration")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func resolve(_ shell: String, _ environment: [String: String] = [:]) -> String? {
            TerminalView.integrationDirectory(shell: shell, resources: resources, environment: environment)
        }
        XCTAssertNil(resolve("/bin/zsh"), "missing wrappers start an ordinary shell")
        try Data().write(to: directory.appendingPathComponent(".zshenv"))
        try Data().write(to: directory.appendingPathComponent("bashrc"))
        XCTAssertEqual(resolve("/bin/zsh"), directory.path)
        XCTAssertEqual(resolve("/opt/homebrew/bin/bash"), directory.path)
        XCTAssertNil(resolve("/opt/homebrew/bin/fish"), "other shells are not integrated")
        XCTAssertEqual(resolve("", ["SHELL": "/bin/bash"]), directory.path, "an empty shell follows $SHELL like the core")
        XCTAssertNil(resolve("", ["SHELL": "/usr/local/bin/nu"]))
        XCTAssertEqual(resolve(""), directory.path, "without $SHELL the core launches /bin/zsh")
        XCTAssertNil(TerminalView.integrationDirectory(shell: "/bin/zsh", resources: nil))
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
