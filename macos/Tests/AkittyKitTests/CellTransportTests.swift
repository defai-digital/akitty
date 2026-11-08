import XCTest
@testable import AkittyKit

/// The negotiated binary cell block must decode to exactly the same `Snapshot` as the JSON cells,
/// and a damaged block must fail cleanly so the caller can fall back.
final class CellTransportTests: XCTestCase {
    private func fingerprint(_ snapshot: Snapshot) -> [String] {
        snapshot.cells.map { cell in
            [String(cell.row), String(cell.col), cell.text, String(describing: cell.fg), String(describing: cell.bg),
             "\(cell.bold)\(cell.italic)\(cell.underline)\(cell.selected)\(cell.search)\(cell.activeSearch)\(cell.wide)",
             String(describing: cell.ustyle), String(describing: cell.ucolor),
             String(describing: cell.strike), String(describing: cell.link)].joined(separator: "|")
        }
    }

    private func assertSameSnapshot(_ a: Snapshot, _ b: Snapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fingerprint(a), fingerprint(b), "cells differ", file: file, line: line)
        XCTAssertEqual(a.revision, b.revision, file: file, line: line)
        XCTAssertEqual(a.cols, b.cols, file: file, line: line)
        XCTAssertEqual(a.rows, b.rows, file: file, line: line)
        XCTAssertEqual(a.lines, b.lines, file: file, line: line)
        XCTAssertEqual(a.partial, b.partial, file: file, line: line)
        XCTAssertEqual(a.dirty, b.dirty, file: file, line: line)
        XCTAssertEqual(a.shift, b.shift, file: file, line: line)
        XCTAssertEqual(a.links, b.links, file: file, line: line)
        XCTAssertEqual(a.cursor.row, b.cursor.row, file: file, line: line)
        XCTAssertEqual(a.cursor.col, b.cursor.col, file: file, line: line)
    }

    private func feedShowcase(_ session: TerminalSession) throws {
        _ = try session.call("feed", ["text": "\u{1b}[2J\u{1b}[H"
            + "\u{1b}[31mred \u{1b}[4m\u{1b}[58;2;200;10;10munder\u{1b}[0m "
            + "\u{1b}]8;;https://example.test/a\u{1b}\\link\u{1b}]8;;\u{1b}\\ "
            + "界 wide e\u{301}combining\r\n"
            + "\u{1b}[38;2;10;200;30m\u{1b}[48;2;1;2;3mRGB\u{1b}[0m\r\n"
            + "boring last line"])
        // Selection and a find hit exercise the attrs bits beyond colour/width.
        _ = try session.call("select", ["start_row": 0, "start_col": 0, "end_row": 0, "end_col": 5])
        _ = try session.call("find", ["text": "link"])
    }

    func testBinaryAndJSONSnapshotsAgree() throws {
        let jsonSession = try TerminalSession(cols: 40, rows: 8, headless: true)
        let binarySession = try TerminalSession(cols: 40, rows: 8, headless: true)
        defer { try? jsonSession.close(); try? binarySession.close() }
        for session in [jsonSession, binarySession] { try feedShowcase(session) }
        let jsonFull = try XCTUnwrap(try jsonSession.snapshot(since: nil, base: nil, binary: false))
        let binaryFull = try XCTUnwrap(try binarySession.snapshot(since: nil, base: nil, binary: true))
        assertSameSnapshot(jsonFull, binaryFull)
        // Scroll both identically: partial + shift replies must agree too.
        for session in [jsonSession, binarySession] {
            _ = try session.call("feed", ["text": "\u{1b}[8;1H\r\none\r\ntwo\r\nthree"])
        }
        let jsonPartial = try XCTUnwrap(try jsonSession.snapshot(since: jsonFull.revision, base: jsonFull, binary: false))
        let binaryPartial = try XCTUnwrap(try binarySession.snapshot(since: binaryFull.revision, base: binaryFull, binary: true))
        XCTAssertEqual(jsonPartial.partial, true)
        XCTAssertNotNil(jsonPartial.shift)
        assertSameSnapshot(jsonPartial, binaryPartial)
    }

    func testBinaryBlockRejectsTruncatedAndCorruptData() throws {
        let session = try TerminalSession(cols: 20, rows: 4, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}[31mhello world"])
        let data = try CoreBridge.raw(["op": "snapshot", "id": session.id, "compact": true, "cells": "binary"])
        let separator = try XCTUnwrap(data.firstIndex(of: 0), "binary reply must carry a NUL separator")
        let head = try JSONSerialization.jsonObject(with: data[..<separator]) as? [String: Any]
        let meta = (head?["data"] as? [String: Any])?["cells_binary"] as? [String: Any]
        let count = try XCTUnwrap(meta?["count"] as? Int)
        let block = data[data.index(after: separator)...]
        XCTAssertEqual(block.count, meta?["bytes"] as? Int)
        XCTAssertEqual(try CellBlock.decode(block, count: count).count, count)
        // A blank screen has no cells; an empty block must decode to no cells, not throw.
        XCTAssertEqual(try CellBlock.decode(Data(), count: 0).count, 0)
        XCTAssertThrowsError(try CellBlock.decode(Data([0]), count: 0))
        // Every truncation and every corrupt length/presence must throw, never crash or return cells.
        for length in 0..<block.count {
            XCTAssertThrowsError(try CellBlock.decode(block.prefix(length), count: count), "prefix \(length)")
        }
        XCTAssertThrowsError(try CellBlock.decode(block, count: count + 1))
        XCTAssertThrowsError(try CellBlock.decode(block, count: count - 1))
        var extra = Data(block); extra.append(0)
        XCTAssertThrowsError(try CellBlock.decode(extra, count: count))
        var corrupt = Data(block); corrupt[14] = 0xff // presence with undefined bits
        XCTAssertThrowsError(try CellBlock.decode(corrupt, count: count))
        corrupt = Data(block); corrupt[15] = 0xff // text_len past the end of the block
        XCTAssertThrowsError(try CellBlock.decode(corrupt, count: count))
    }
}
