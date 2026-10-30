import XCTest
import Metal
@testable import AkittyKit

final class RasterizerTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 18)
    private let cols = 40, rows = 12
    private var size: CGSize { CGSize(width: CGFloat(cols) * cell.width + 16, height: CGFloat(rows) * cell.height + 16) }

    private func bytes(_ context: CGContext) -> Data { Data(bytes: context.data!, count: context.bytesPerRow * context.height) }

    /// Small deterministic generator so a failure reproduces.
    private struct Lcg { var state: UInt64
        mutating func next(_ bound: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(bound)) } }

    private func edit(_ rng: inout Lcg) -> String {
        let row = rng.next(rows) + 1, col = rng.next(cols - 4) + 1
        switch rng.next(12) {
        case 0: return "\u{1b}[\(row);\(col)H\u{1b}[3\(rng.next(7) + 1)mword\u{1b}[0m"
        case 1: return "\u{1b}[\(row);\(col)H\u{1b}[1;4mBold\u{1b}[0m"
        case 2: return "\u{1b}[\(row);1H\u{1b}[2K"
        case 3: return "\u{1b}[\(row);\(col)H\u{1b}[7mrev\u{1b}[0m"
        case 4: return "\u{1b}[\(row);\(col)H漢字"
        case 5: return "\u{1b}[\(rows);1H\r\nscroll \(rng.next(100))"
        case 6: return "\u{1b}[\(row);\(col)H\u{1b}[4:3m\u{1b}[58;2;255;0;0mcurly\u{1b}[0m"
        case 7: return "\u{1b}[\(row);\(col)H\u{1b}[9mgone\u{1b}[0m"
        case 8: return "\u{1b}[\(row);\(col)H╭─┬╮│┃╬▀▄█░▒▓⣿⠁"
        case 9: return "\u{1b}[\(row);\(col)H👨\u{200D}👩\u{200D}👧🇯🇵❤\u{FE0F}x"
        case 10: return "\u{1b}[\(row);\(col)H한글かな中\u{1b}[7m╰┴╯\u{1b}[0m"
        default: return rng.next(6) == 0 ? "\u{1b}[2J" : "\u{1b}[\(row);\(col)H\u{1b}[48;5;\(rng.next(200))m   \u{1b}[0m"
        }
    }

    /// Batched glyphs skip the per-cell clip only where it cannot change a pixel, so every frame must match the
    /// one-glyph-at-a-time path byte for byte, whatever the scale, font, style or layer.
    func testBatchedGlyphsMatchClippedDrawingExactly() throws {
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        var rng = Lcg(state: 7)
        for _ in 0..<60 { _ = try session.call("feed", ["text": edit(&rng)]) }
        // Plain rows written last so no clear wipes them. Italic and underscores overhang their cells, so they take
        // the clipped fallback.
        for row in 1...4 {
            _ = try session.call("feed", ["text": "\u{1b}[\(row);1Hplain ascii_text {}[]|/ 0123456789 MWmw \u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m"])
        }
        let snapshot = try XCTUnwrap(try session.snapshot())
        for (scale, font) in [(CGFloat(2), "Menlo"), (1, "Menlo"), (2, "Courier New"), (3, "Menlo")] {
            let batched = GridRasterizer(), clipped = GridRasterizer(batchesGlyphs: false)
            let fast = try batched.render(snapshot: snapshot, damage: nil, size: size, scale: scale, fontName: font, fontSize: 13, cellSize: cell, composition: "", reuse: false)
            let slow = try clipped.render(snapshot: snapshot, damage: nil, size: size, scale: scale, fontName: font, fontSize: 13, cellSize: cell, composition: "", reuse: false)
            XCTAssertEqual(bytes(fast.context), bytes(slow.context), "\(font) @\(scale)x")
            // At 1x a glyph nearly fills its 8-point cell, so few can skip the clip; Retina scales batch most of them.
            XCTAssertGreaterThan(batched.batchedGlyphs, scale >= 2 ? 100 : 0, "\(font) @\(scale)x")
            XCTAssertEqual(clipped.batchedGlyphs, 0)
            let layers = try GridRasterizer().renderLayers(snapshot: snapshot, damage: nil, size: size, scale: scale, fontName: font, fontSize: 13, cellSize: cell, composition: "", reuse: false)
            let reference = try GridRasterizer(batchesGlyphs: false).renderLayers(snapshot: snapshot, damage: nil, size: size, scale: scale, fontName: font, fontSize: 13, cellSize: cell, composition: "", reuse: false)
            XCTAssertEqual(bytes(layers.foreground), bytes(reference.foreground), "layered \(font) @\(scale)x")
        }
    }

    func testIncrementalFramesMatchFullRepaint() throws {
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        let incremental = GridRasterizer()
        var rng = Lcg(state: 42)
        var held: Snapshot?
        var damage: Set<Int>? = nil
        var rendered = 0, partialFrames = 0
        for step in 0..<150 {
            _ = try session.call("feed", ["text": edit(&rng)])
            if let next = try session.snapshot(since: held?.revision, base: held) {
                if next.partial == true, let dirty = next.dirty { damage?.formUnion(dirty) } else { damage = nil }
                held = next
            }
            // Skip some frames, like a busy main thread coalescing redraws: damage must accumulate across them.
            guard step % 3 != 1, let snapshot = held else { continue }
            let composition = step % 11 == 0 ? "ab" : ""
            let frame = try incremental.render(snapshot: snapshot, damage: damage, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: composition)
            damage = []
            let full = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: composition)
            XCTAssertEqual(bytes(frame.context), bytes(full), "step \(step) differs from a full repaint")
            rendered += 1
            if frame.damage != nil { partialFrames += 1 }
        }
        XCTAssertGreaterThan(rendered, 50)
        XCTAssertGreaterThan(partialFrames, 20, "most frames should have been incremental")
    }

    func testDamageCoversTheChangedAndCursorRows() throws {
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}[1;1Hfirst\u{1b}[8;1Hlater"])
        var held = try XCTUnwrap(try session.snapshot())
        let rasterizer = GridRasterizer()
        let first = try rasterizer.render(snapshot: held, damage: nil, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        XCTAssertNil(first.damage, "the first frame is a full repaint")

        _ = try session.call("feed", ["text": "\u{1b}[4;3Hx"])
        held = try XCTUnwrap(try session.snapshot(since: held.revision, base: held))
        XCTAssertEqual(held.partial, true)
        let second = try rasterizer.render(snapshot: held, damage: Set(held.dirty ?? []), size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        let damage = try XCTUnwrap(second.damage)
        // Row 3 (0-based) changed; the cursor moved from row 7 to row 3, so the old cursor row repaints too.
        let rowTop = Int((8 + 3 * cell.height) * 2), rowBottom = Int((8 + 4 * cell.height) * 2)
        XCTAssertLessThanOrEqual(damage.lowerBound, rowTop)
        XCTAssertGreaterThanOrEqual(damage.upperBound, rowBottom)
        XCTAssertLessThan(damage.count, second.context.height)

        // A different size is a new layout: full repaint again.
        let resized = try rasterizer.render(snapshot: held, damage: [], size: CGSize(width: size.width + 8, height: size.height), scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        XCTAssertNil(resized.damage)
        XCTAssertNotEqual(resized.context.width, second.context.width)
    }

    func testStatelessMakeNeverSharesABitmap() throws {
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "hello"])
        let snapshot = try XCTUnwrap(try session.snapshot())
        let a = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 1, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        let b = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 1, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        XCTAssertNotEqual(a.data, b.data)
        XCTAssertEqual(bytes(a), bytes(b))
    }

    @MainActor func testDamageOnlyTextureUploadMatchesTheBitmap() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        let rasterizer = GridRasterizer()
        _ = try session.call("feed", ["text": "\u{1b}[1;1Hone\u{1b}[6;1Hsix"])
        var held = try XCTUnwrap(try session.snapshot())
        var frame = try rasterizer.render(snapshot: held, damage: nil, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        try presenter.update(bitmap: frame.context, damage: frame.damage)
        let texture = try XCTUnwrap(presenter.texture)

        for text in ["\u{1b}[3;5Hmiddle", "\u{1b}[11;1H\u{1b}[31mbottom", "\u{1b}[1;1H\u{1b}[2J"] {
            _ = try session.call("feed", ["text": text])
            held = try XCTUnwrap(try session.snapshot(since: held.revision, base: held))
            frame = try rasterizer.render(snapshot: held, damage: Set(held.dirty ?? []), size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
            try presenter.update(bitmap: frame.context, damage: frame.damage)
            XCTAssertTrue(presenter.texture === texture, "no GPU work pending, so the texture is updated in place")
            var readback = Data(count: frame.context.bytesPerRow * frame.context.height)
            readback.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: frame.context.bytesPerRow, from: MTLRegionMake2D(0, 0, frame.context.width, frame.context.height), mipmapLevel: 0) }
            XCTAssertEqual(readback, bytes(frame.context), "texture differs after \(text.debugDescription)")
        }
    }
}
