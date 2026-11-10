import XCTest
import AppKit
@testable import AkittyKit

/// xterm legacy encoding for editing and function keys when no Kitty keyboard mode is active.
final class LegacyKeyTests: XCTestCase {
    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], app: Bool = false) -> String? {
        TerminalView.legacyEditingKey(keyCode: code, modifiers: modifiers, appCursor: app)
    }

    func testHomeAndEndFollowApplicationCursorMode() {
        XCTAssertEqual(key(115), "\u{1b}[H")
        XCTAssertEqual(key(119), "\u{1b}[F")
        XCTAssertEqual(key(115, app: true), "\u{1b}OH")
        XCTAssertEqual(key(119, app: true), "\u{1b}OF")
    }

    func testModifiersAddAnXtermParameter() {
        XCTAssertEqual(key(115, .control), "\u{1b}[1;5H")
        XCTAssertEqual(key(119, .shift, app: true), "\u{1b}[1;2F", "a modified key ignores application cursor mode")
        XCTAssertEqual(key(116, .shift), "\u{1b}[5;2~")
        XCTAssertEqual(key(121, [.control, .shift]), "\u{1b}[6;6~")
        XCTAssertEqual(key(117, .option), "\u{1b}[3;3~")
        XCTAssertEqual(key(122, .shift), "\u{1b}[1;2P")
        XCTAssertEqual(key(96, .control), "\u{1b}[15;5~")
    }

    func testUnmodifiedFunctionKeysKeepTheirSequences() {
        XCTAssertEqual(key(122), "\u{1b}OP")
        XCTAssertEqual(key(118, app: true), "\u{1b}OS")
        XCTAssertEqual(key(111), "\u{1b}[24~")
        XCTAssertEqual(key(114), "\u{1b}[2~")
        XCTAssertNil(key(36), "Return stays with the plain-key table")
    }
}
