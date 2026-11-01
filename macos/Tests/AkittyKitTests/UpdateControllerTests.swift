import XCTest
@testable import AkittyKit

/// Reminder text is untrusted feed display text: control and Unicode format (Cf) scalars are stripped, edge
/// whitespace is trimmed, and the result is capped at 32 characters. Text that sanitizes to empty is not a
/// version — it must clear the reminder rather than create a blank "Update Available" button.
final class UpdateControllerTests: XCTestCase {
    @MainActor func testEmptyReminderTextClearsTheReminderInsteadOfBlank() {
        let updater = UpdateController()
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder("")

        XCTAssertNil(updater.availableVersion, "an empty reminder is not a version; the reminder stays cleared")
        XCTAssertEqual(seen, [nil], "the callback announces the cleared reminder, not a blank string")
    }

    @MainActor func testControlOnlyReminderTextClearsTheReminder() {
        let updater = UpdateController()
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder("\u{0007}\u{0000}\n\t\u{001B}")

        XCTAssertNil(updater.availableVersion, "text that is all control characters sanitizes to empty and clears")
        XCTAssertEqual(seen, [nil])
    }

    @MainActor func testValidVersionIsKeptAndAnnounced() {
        let updater = UpdateController()
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder("1.2.3")

        XCTAssertEqual(updater.availableVersion, "1.2.3")
        XCTAssertEqual(seen, ["1.2.3"])
    }

    @MainActor func testControlCharactersInsideAVersionAreStrippedAndTheVersionIsKept() {
        let updater = UpdateController()
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder("1.\u{0007}2.\n3")

        XCTAssertEqual(updater.availableVersion, "1.2.3", "sanitizing must not discard a real version")
        XCTAssertEqual(seen, ["1.2.3"])
    }

    @MainActor func testLongVersionIsCappedAtThirtyTwoCharacters() {
        let updater = UpdateController()
        updater.setReminder(String(repeating: "9", count: 40))

        XCTAssertEqual(updater.availableVersion, String(repeating: "9", count: 32))
    }

    @MainActor func testNilReminderClearsAndAnnounces() {
        let updater = UpdateController()
        updater.setReminder("2.0.0")
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder(nil)

        XCTAssertNil(updater.availableVersion)
        XCTAssertEqual(seen, [nil])
    }

    @MainActor func testAsciiSpaceOnlyReminderTextClearsInsteadOfBlank() {
        let updater = UpdateController()
        updater.setReminder("2.0.0")
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder("   ")

        XCTAssertNil(updater.availableVersion, "spaces render blank, so they are not a version")
        XCTAssertEqual(seen, [nil], "the callback announces the cleared reminder, not spaces")
    }

    @MainActor func testNoBreakAndIdeographicSpaceOnlyReminderTextClearsInsteadOfBlank() {
        let updater = UpdateController()
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder("\u{00A0}\u{3000}\u{00A0}\u{3000}")

        XCTAssertNil(updater.availableVersion, "NBSP and the ideographic space are blank separators, not version text")
        XCTAssertEqual(seen, [nil])
    }

    @MainActor func testZeroWidthAndDirectionalFormattingOnlyReminderTextClearsInsteadOfBlank() {
        let updater = UpdateController()
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        // ZWSP, ZWNJ, ZWJ, LRM, RLM, LRE/RLE/PDF/LRO/RLO, LRI/RLI/FSI/PDI, BOM.
        updater.setReminder("\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")

        XCTAssertNil(updater.availableVersion, "format scalars draw nothing, so they are not a version")
        XCTAssertEqual(seen, [nil])
    }

    @MainActor func testMixedBlankReminderTextClearsInsteadOfBlank() {
        let updater = UpdateController()
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder("\u{200B} \u{00A0}\u{3000}\u{200E}\u{FEFF}")

        XCTAssertNil(updater.availableVersion, "blank-and-invisible text sanitizes to empty and clears")
        XCTAssertEqual(seen, [nil])
    }

    @MainActor func testEdgeWhitespaceAndFormattingAreTrimmedAroundAVersion() {
        let updater = UpdateController()
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder("\u{00A0}\u{3000} 2.0.0 \u{200B}\u{200E}\u{00A0}")

        XCTAssertEqual(updater.availableVersion, "2.0.0", "trimming must not discard a real version")
        XCTAssertEqual(seen, ["2.0.0"])
    }

    @MainActor func testFormatScalarsInsideAVersionAreStrippedAndTheVersionIsKept() {
        let updater = UpdateController()
        var seen = [String?]()
        updater.onReminderChanged = { seen.append($0) }

        updater.setReminder("1.2\u{200B}.\u{200E}3\u{FEFF}")

        XCTAssertEqual(updater.availableVersion, "1.2.3", "only edge whitespace is trimmed; embedded formatting is stripped")
        XCTAssertEqual(seen, ["1.2.3"])
    }

    @MainActor func testInteriorSpacesSurviveBecauseOnlyEdgeWhitespaceIsTrimmed() {
        let updater = UpdateController()
        updater.setReminder("  2.0 Beta  ")

        XCTAssertEqual(updater.availableVersion, "2.0 Beta", "spaces inside display text are meaningful")
    }

    @MainActor func testCapAppliesToTextAfterTrimming() {
        let updater = UpdateController()
        updater.setReminder("\u{00A0}   " + String(repeating: "9", count: 40) + "  \u{3000}")

        XCTAssertEqual(updater.availableVersion, String(repeating: "9", count: 32), "padding must not displace version text")
    }
}