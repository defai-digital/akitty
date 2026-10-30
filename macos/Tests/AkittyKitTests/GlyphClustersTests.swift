import XCTest
@testable import AkittyKit

final class GlyphClustersTests: XCTestCase {
    /// Feeds `text` to a fresh headless core and returns the cells it reports, in row-major order.
    private func readCells(_ text: String, rows: Int = 6, cols: Int = 20) throws -> [Cell] {
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": text])
        return try XCTUnwrap(try session.snapshot()).cells
    }

    private func visible(_ drawn: [GlyphClusters.Drawn]) -> [GlyphClusters.Drawn] { drawn.filter { !$0.text.isEmpty } }
}

extension GlyphClustersTests {
    func testZwjSequenceStartingWithANarrowPieceStillGetsTwoColumns() throws {
        // The pride flag's first piece is narrow (a flag with VS16) and its last, the rainbow, is wide.
        let cells = try readCells("\u{1b}[1;1H🏳\u{FE0F}\u{200D}🌈x")
        let items = visible(GlyphClusters.merge(cells))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.columns, 2, "the whole sequence is an emoji and needs a full-size box")
        XCTAssertEqual(items.last?.text, "x")
    }
    func testZwjBetweenNarrowTextStaysOneColumn() throws {
        let items = visible(GlyphClusters.merge(try readCells("\u{1b}[1;1Ha\u{200D}b")))
        XCTAssertEqual(items.first?.columns, 1)
    }
    func testFamilyEmojiIsOneItemAndTheNextCharacterKeepsItsColumn() throws {
        let cells = try readCells("\u{1b}[1;1H👨\u{200D}👩\u{200D}👧x")
        let drawn = GlyphClusters.merge(cells)
        let items = visible(drawn)
        XCTAssertEqual(items.count, 2, "the three joined faces are one glyph")
        XCTAssertEqual(items.first?.text, "👨\u{200D}👩\u{200D}👧")
        XCTAssertEqual(items.first?.columns, 2)
        XCTAssertEqual(items.first?.cell.col, 0)
        let x = try XCTUnwrap(cells.first { $0.text == "x" })
        XCTAssertEqual(items.last?.text, "x")
        XCTAssertEqual(items.last?.cell.col, x.col)
        XCTAssertFalse(drawn.contains { $0.cell.row == 0 && ($0.cell.col == 2 || $0.cell.col == 4) }, "absorbed cells are not returned")
    }

    func testRegionalIndicatorPairIsOneFlag() throws {
        let cells = try readCells("\u{1b}[1;1H🇯🇵x")
        let indicators = cells.filter {
            $0.text.unicodeScalars.count == 1 && $0.text.unicodeScalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
        }
        XCTAssertEqual(indicators.count, 2, "the core lays a flag out as one cell per regional indicator")
        XCTAssertEqual(indicators[1].col, indicators[0].col + (indicators[0].wide ? 2 : 1), "the pair is adjacent")
        let items = visible(GlyphClusters.merge(cells))
        XCTAssertEqual(items.first?.text, "🇯🇵")
        XCTAssertEqual(items.first?.columns, 2)
        XCTAssertEqual(items.first?.cell.col, indicators[0].col)
        let x = try XCTUnwrap(cells.first { $0.text == "x" })
        XCTAssertEqual(items.last?.text, "x")
        XCTAssertEqual(items.last?.cell.col, x.col)
    }

    func testHeartAndCjkCellsAreDrawnUnchanged() throws {
        let cells = try readCells("\u{1b}[1;1H❤\u{FE0F}x\u{1b}[2;1H中文a")
        let drawn = GlyphClusters.merge(cells)
        let row0 = visible(drawn.filter { $0.cell.row == 0 })
        XCTAssertEqual(row0.map(\.text), ["❤\u{FE0F}", "x"], "VS16 does not widen the narrow heart")
        XCTAssertEqual(row0.map(\.columns), [1, 1])
        let row1 = visible(drawn.filter { $0.cell.row == 1 })
        XCTAssertEqual(row1.map(\.text), ["中", "文", "a"])
        XCTAssertEqual(row1.map(\.columns), [2, 2, 1], "wide cells report two columns")
    }
}

extension GlyphClustersTests {
    func testMergingNeverCrossesRows() throws {
        let cells = try readCells("\u{1b}[1;1H👨\u{200D}\u{1b}[2;1H👩x")
        let drawn = GlyphClusters.merge(cells)
        let row0 = visible(drawn.filter { $0.cell.row == 0 })
        XCTAssertEqual(row0.map(\.text), ["👨\u{200D}"], "an emoji on the next row is not joined")
        XCTAssertEqual(row0.map(\.columns), [2])
        XCTAssertFalse(drawn.contains { $0.cell.row == 0 && $0.text.contains("👩") })
        XCTAssertEqual(visible(drawn.filter { $0.cell.row == 1 }).map(\.text), ["👩", "x"])
    }

    func testLoneTrailingZwjCellIsReturnedUnchanged() throws {
        let cells = try readCells("\u{1b}[1;1Ha👨\u{200D}")
        let drawn = visible(GlyphClusters.merge(cells))
        XCTAssertEqual(drawn.map(\.text), ["a", "👨\u{200D}"])
        XCTAssertEqual(drawn.map(\.columns), [1, 2])
        // Compare scalars: String.hasPrefix works on grapheme clusters, and "👨\u{200D}" is a different cluster from "👨".
        XCTAssertEqual(drawn.last?.cell.col, cells.first { $0.text.unicodeScalars.first == "👨" }?.col)
    }

    func testPlainAsciiPassesThroughOneForOne() throws {
        let cells = try readCells("abc")
        XCTAssertEqual(cells.count, 3)
        let drawn = GlyphClusters.merge(cells)
        XCTAssertEqual(drawn.count, cells.count)
        for (source, item) in zip(cells, drawn) {
            XCTAssertEqual(item.text, source.text)
            XCTAssertEqual(item.cell.row, source.row)
            XCTAssertEqual(item.cell.col, source.col)
            XCTAssertEqual(item.cell.wide, source.wide)
            XCTAssertEqual(item.columns, 1)
        }
    }
}
