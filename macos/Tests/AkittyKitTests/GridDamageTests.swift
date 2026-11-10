import XCTest
@testable import AkittyKit

final class GridDamageTests: XCTestCase {
    func testCoalescedScrollsRelocateAlreadyDirtyRowsAndResizeInvalidatesTheBase() throws {
        let session = try TerminalSession(cols: 40, rows: 8, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": (0..<8).map { "\u{1b}[\($0 + 1);1Hline \($0)" }.joined()])
        var held = try XCTUnwrap(try session.snapshot())
        var damage = GridDamage(rows: [])
        func update(_ text: String) throws {
            _ = try session.call("feed", ["text": text])
            held = try XCTUnwrap(try session.snapshot(since: held.revision, base: held))
            damage.merge(held)
        }
        try update("\u{1b}[6;1HX")
        XCTAssertEqual(damage.rows, [5])
        try update("\u{1b}[8;1H\r\nnew one")
        XCTAssertEqual(held.shift, 1)
        XCTAssertEqual(damage.scroll, 1)
        XCTAssertEqual(damage.rows, [4, 7])
        try update("\u{1b}[2;1HY")
        try update("\u{1b}[8;1H\r\nnew two\r\nnew three")
        XCTAssertEqual(held.shift, 2)
        XCTAssertEqual(damage.scroll, 3)
        XCTAssertEqual(damage.rows, [2, 5, 6, 7])

        var unknown = GridDamage()
        unknown.merge(held)
        XCTAssertNil(unknown.rows)
        XCTAssertEqual(unknown.scroll, 0)
        damage = GridDamage(rows: [])
        for index in 0..<4 { try update("\u{1b}[8;1H\r\nextra \(index) a\r\nextra \(index) b") }
        XCTAssertNil(damage.rows, "scrolling beyond the retained frame requires a full repaint")
        XCTAssertEqual(damage.scroll, 0)
        damage = GridDamage(rows: [])
        _ = try session.call("resize", ["cols": 41, "rows": 8])
        held = try XCTUnwrap(try session.snapshot(since: held.revision, base: held))
        damage.merge(held)
        XCTAssertNil(damage.rows)
        XCTAssertEqual(damage.scroll, 0)
    }
}
