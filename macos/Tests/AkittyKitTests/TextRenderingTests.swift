import XCTest
@testable import AkittyKit

/// Renders real snapshots through `GridRasterizer` and inspects pixels: what the user sees, not the helpers behind it.
final class TextRenderingTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 18), scale = 2
    private let cols = 24, rows = 8, margin = 8
    private var size: CGSize { CGSize(width: CGFloat(cols) * cell.width + 16, height: CGFloat(rows) * cell.height + 16) }

    private func render(_ text: String, cjkFontName: String = "") throws -> CGContext {
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}[?25l" + text])
        let snapshot = try XCTUnwrap(try session.snapshot())
        return try GridRasterizer.make(snapshot: snapshot, size: size, scale: CGFloat(scale), fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "", cjkFontName: cjkFontName)
    }
    private func pixel(_ context: CGContext, _ x: Int, _ y: Int) -> [UInt8] {
        let data = context.data!.assumingMemoryBound(to: UInt8.self), offset = y * context.bytesPerRow + x * 4
        return [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
    }
    /// Device-pixel bounds of everything that is not background inside `x`, `y` ranges, or nil when nothing is drawn.
    private func ink(_ context: CGContext, x: Range<Int>, y: Range<Int>) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        // The bottom-right corner is always empty margin, so it holds the terminal background whatever its exact encoding.
        let background = pixel(context, context.width - 1, context.height - 1)
        var box: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for py in y { for px in x where pixel(context, px, py) != background {
            box = (min(box?.minX ?? px, px), max(box?.maxX ?? px, px), min(box?.minY ?? py, py), max(box?.maxY ?? py, py))
        } }
        return box
    }
    /// Device-pixel ranges of grid cells `col..<col+columns` on `row`.
    private func region(row: Int, col: Int, columns: Int) -> (x: Range<Int>, y: Range<Int>) {
        let w = Int(cell.width) * scale, h = Int(cell.height) * scale, m = margin * scale
        return ((m + col * w)..<(m + (col + columns) * w), (m + row * h)..<(m + (row + 1) * h))
    }

    func testAsciiRenderingIsIdenticalWhateverCjkFontIsChosen() throws {
        let text = "\u{1b}[1;1HHello, world 123 {}[]<>"
        let a = try render(text), b = try render(text, cjkFontName: "PingFang TC"), c = try render(text, cjkFontName: "Hiragino Sans")
        let length = a.bytesPerRow * a.height
        XCTAssertEqual(Data(bytes: a.data!, count: length), Data(bytes: b.data!, count: length))
        XCTAssertEqual(Data(bytes: a.data!, count: length), Data(bytes: c.data!, count: length))
    }
    func testWideGlyphIsCentredInItsTwoColumnBoxAndStaysInside() throws {
        let context = try render("\u{1b}[2;3H中")
        let box = region(row: 1, col: 2, columns: 2)
        let found = try XCTUnwrap(ink(context, x: box.x, y: box.y), "the glyph is drawn")
        let left = found.minX - box.x.lowerBound, right = box.x.upperBound - 1 - found.maxX
        XCTAssertLessThanOrEqual(abs(left - right), 3, "ink is centred (left gap \(left), right gap \(right))")
        let wider = (box.x.lowerBound - 6)..<(box.x.upperBound + 6)
        XCTAssertEqual(ink(context, x: wider, y: box.y)?.minX, found.minX, "nothing leaks into the neighbouring columns")
        XCTAssertEqual(ink(context, x: wider, y: box.y)?.maxX, found.maxX)
    }
    func testTallGlyphStaysInsideItsRow() throws {
        let context = try render("\u{1b}[3;1H鬱\u{1b}[3;5H龍")
        for col in [0, 4] {
            let box = region(row: 2, col: col, columns: 2)
            let found = try XCTUnwrap(ink(context, x: box.x, y: box.y))
            XCTAssertGreaterThan(found.maxY - found.minY, 12 * scale / 2, "the glyph is drawn at a legible size")
        }
        let above = region(row: 1, col: 0, columns: 8), below = region(row: 3, col: 0, columns: 8)
        XCTAssertNil(ink(context, x: above.x, y: above.y), "nothing spills into the row above")
        XCTAssertNil(ink(context, x: below.x, y: below.y), "nothing spills into the row below")
    }
    func testFamilyEmojiDrawsAsOneGlyphInItsFirstTwoColumns() throws {
        let context = try render("\u{1b}[1;1H👨\u{200D}👩\u{200D}👧x")
        let first = region(row: 0, col: 0, columns: 2), absorbed = region(row: 0, col: 2, columns: 4), after = region(row: 0, col: 6, columns: 1)
        XCTAssertNotNil(ink(context, x: first.x, y: first.y), "the cluster is drawn in its first box")
        XCTAssertNil(ink(context, x: absorbed.x, y: absorbed.y), "the joined faces are not drawn again as separate glyphs")
        XCTAssertNotNil(ink(context, x: after.x, y: after.y), "following text keeps its wcwidth column")
    }
    func testFlagDrawsAsOneGlyphInItsFirstTwoColumns() throws {
        let context = try render("\u{1b}[1;1H🇯🇵x")
        let first = region(row: 0, col: 0, columns: 2), after = region(row: 0, col: 2, columns: 1)
        XCTAssertNotNil(ink(context, x: first.x, y: first.y), "the flag is drawn in its first box")
        // The two indicators are consecutive wcwidth cells; the flag occupies the first, so what follows is plain text.
        XCTAssertNotNil(ink(context, x: after.x, y: after.y), "the next character keeps its column")
    }
    func testBorderedBoxHasNoGapsBetweenRows() throws {
        let context = try render("\u{1b}[1;1H╭──╮\u{1b}[2;1H│  │\u{1b}[3;1H│  │\u{1b}[4;1H│  │\u{1b}[5;1H╰──╯")
        let x = (margin + Int(cell.width) / 2) * scale   // the left border's column of pixels, mid-cell
        // Start at the straight stub of ╭ and stop at the straight stub of ╰; between them the arcs bend away from the column.
        let h = Int(cell.height) * scale, top = margin * scale + h - 6, bottom = margin * scale + 4 * h + 6
        let column = (x - 1)..<(x + 1)
        for y in top..<bottom { XCTAssertNotNil(ink(context, x: column, y: y..<(y + 1)), "gap in the left border at pixel row \(y)") }
    }
}
