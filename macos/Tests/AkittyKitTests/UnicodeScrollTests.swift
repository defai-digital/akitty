import XCTest
@testable import AkittyKit

final class UnicodeScrollTests: XCTestCase {
    private func pixels(_ context: CGContext) -> Data { Data(bytes: context.data!, count: context.bytesPerRow * context.height) }

    func testUnicodeScrollMatchesFullPaintingAcrossFontsAndDeviceScales() throws {
        for (font, fontSize, cell) in [("Menlo", CGFloat(13), CGSize(width: 8, height: 18)),
                                       ("Courier New", 13, CGSize(width: 8.5, height: 19)),
                                       ("Menlo", 17.25, CGSize(width: 9.5, height: 21)),
                                       ("Menlo", 13.5, CGSize(width: 8.5, height: 20)),
                                       ("Menlo", 13, CGSize(width: 8, height: 20))] {
            for scale in [CGFloat(1), 2, 3] { try compareScroll(font: font, fontSize: fontSize, cell: cell, scale: scale) }
        }
    }

    private func compareScroll(font: String, fontSize: CGFloat, cell: CGSize, scale: CGFloat) throws {
        let cols = 64, rows = 12
        let size = CGSize(width: CGFloat(cols) * cell.width + 16, height: CGFloat(rows) * cell.height + 16)
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        func line(_ value: Int) -> String {
            let style = value % 5 == 0 ? "\u{1b}[3;4;9m" : "\u{1b}[38;2;90;180;240m"
            return "\u{1b}[0m\(value) \(style)漢字かな한글 👩🏽‍💻 e\u{301} 🇯🇵 Ⅲℓ╭─┬▄⣿\u{1b}[0m"
        }
        _ = try session.call("feed", ["text": (0..<rows).map { "\u{1b}[\($0 + 1);1H" + line($0) }.joined()])
        var held = try XCTUnwrap(try session.snapshot())
        let incremental = GridRasterizer()
        _ = try incremental.render(snapshot: held, damage: nil, size: size, scale: scale, fontName: font, fontSize: fontSize, cellSize: cell, composition: "")
        var reused = 0
        for step in 0..<18 {
            var damage = GridDamage(rows: [])
            if step % 4 < 2 {
                _ = try session.call("select", ["start_row": 1, "start_col": 3,
                    "end_row": step % 4 == 0 ? 3 : 1, "end_col": step % 4 == 0 ? 40 : 3])
                if let next = try session.snapshot(since: held.revision, base: held) { damage.merge(next); held = next }
            }
            for offset in 0..<(step % 3 + 1) {
                let cursor = step % 6 == 0 ? "\u{1b}[?25l" : "\u{1b}[?25h"
                _ = try session.call("feed", ["text": cursor + "\u{1b}[\(rows);1H\r\n" + line(rows + step * 3 + offset)])
                let next = try XCTUnwrap(try session.snapshot(since: held.revision, base: held))
                damage.merge(next); held = next
            }
            let frame = try incremental.render(snapshot: held, damage: damage.rows, scroll: damage.scroll, size: size, scale: scale, fontName: font, fontSize: fontSize, cellSize: cell, composition: "")
            let full = try GridRasterizer.make(snapshot: held, size: size, scale: scale, fontName: font, fontSize: fontSize, cellSize: cell, composition: "")
            XCTAssertEqual(pixels(frame.context), pixels(full), "\(font) \(fontSize) @\(scale)x frame \(step), scroll \(damage.scroll)/\(frame.scrolledRows)")
            if frame.scrolledRows > 0 {
                reused += 1
                XCTAssertEqual(frame.damage, Int(GridRasterizer.margin * scale)..<Int((GridRasterizer.margin + CGFloat(rows) * cell.height) * scale), "the upload must cover repaired glyphs and every moved row")
            }
        }
        if fontSize == 13 { XCTAssertGreaterThan(reused, 0, "the Unicode reuse branch must actually execute") }
    }

    func testComplexScrollKeepsGeometryAndCompositionFallbacksPixelExact() throws {
        let cols = 40, rows = 8, cell = CGSize(width: 8, height: 18)
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": (0..<rows).map { "\u{1b}[\($0 + 1);1H漢字 👩🏽‍💻 \($0)" }.joined()])
        for (scale, height, marked) in [(CGFloat(1.25), CGFloat(160), ""), (2, 151, ""), (2, 160, "IME")] {
            let size = CGSize(width: 336, height: height), rasterizer = GridRasterizer()
            var held = try XCTUnwrap(try session.snapshot())
            _ = try rasterizer.render(snapshot: held, damage: nil, size: size, scale: scale, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: marked)
            _ = try session.call("feed", ["text": "\u{1b}[\(rows);1H\r\n漢字 👩🏽‍💻 next"])
            held = try XCTUnwrap(try session.snapshot(since: held.revision, base: held))
            let frame = try rasterizer.render(snapshot: held, damage: Set(held.dirty ?? []), scroll: held.shift ?? 1, size: size, scale: scale, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: marked)
            let full = try GridRasterizer.make(snapshot: held, size: size, scale: scale, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: marked)
            XCTAssertEqual(pixels(frame.context), pixels(full)); XCTAssertEqual(frame.scrolledRows, 0)
        }
    }
}
