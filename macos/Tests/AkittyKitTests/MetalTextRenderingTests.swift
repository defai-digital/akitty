import XCTest
import CoreGraphics
import CoreText
import Metal
@testable import AkittyKit

/// The GPU glyph-atlas path: pixel equivalence with the CPU rasterizer on the content it covers, the fallback
/// decisions that keep every other case on the software reference, and the atlas/instance-buffer bounds.
final class MetalTextRenderingTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 18)
    private let cols = 40, rows = 12
    private var size: CGSize { CGSize(width: CGFloat(cols) * cell.width + 16, height: CGFloat(rows) * cell.height + 16) }
    private func bitmapSize(_ scale: CGFloat) -> (width: Int, height: Int) {
        (Int(ceil(size.width * scale)), Int(ceil(size.height * scale)))
    }

    // MARK: Equivalence with the software reference

    /// Ordinary ASCII at every validated backing scale: the atlas frame must reproduce the CPU rasterizer's
    /// pixels. macOS text smoothing depends on the text colour, so the atlas keys masks by colour; a residual
    /// difference of one or two 8-bit steps on antialiased edges is the only acceptable deviation.
    @MainActor func testAsciiFrameMatchesTheCpuRasterizerAtEveryValidatedScale() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let cells = line(0, "The quick brown fox 0123456789")
            + line(1, "jumps over the lazy dog []{}()<>")
            + line(2, "!@#$%^&*-_=+|\\/:;\"',.?")
            + line(4, "Mixed CASE and  spacing", col: 2)
            + line(6, "A")
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(scale)x max channel difference \(result.max)")
            XCTAssertGreaterThan(result.exact, 0.95, "\(scale)x identical pixels \(result.exact)")
        }
    }

    @MainActor func testFittedMonochromeFrameMatchesTheCpuRasterizerAtEveryValidatedScale() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let cells = line(0, "éñßαλ€") + line(1, "ⅢℓΊ→", Style(fg: [240, 180, 90]))
            + line(2, "ÉÅÇ∫", Style(bold: true)) + line(3, "é", Style(italic: true))
            + line(4, "\u{00a0}") + line(5, "漢", Style(bold: true, italic: true))
            + line(6, "⎛∫Ⅲℓ")
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            XCTAssertGreaterThan(paintedPixels(cpu), 0, "\(scale)x fitted CPU reference painted glyphs")
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(scale)x fitted max channel difference \(result.max)")
            XCTAssertGreaterThan(result.exact, 0.90, "\(scale)x fitted identical pixels \(result.exact)")
        }
    }

    /// Wide CJK at every validated backing scale. At 13 pt in an 8x18 cell an ideograph's ink already fits
    /// its two-column box, so this covers placement at scale 1; the shrinking case is a separate test.
    @MainActor func testWideCjkFrameMatchesTheCpuRasterizerAtEveryValidatedScale() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        // Ideographs, hangul, fullwidth punctuation and forms, ink below the baseline, dense strokes, an
        // ideographic space whose ink is empty, narrow text directly beside a wide cell, all four faces, and
        // ambiguous-width scalars the core marked wide.
        let cells = wideLine(0, "漢字日本語") + wideLine(1, "中文한글", Style(fg: [240, 180, 90]))
            + wideLine(2, "、。「」＿") + wideLine(3, "ＡＢ", Style(bold: true)) + wideLine(4, "鬱龘")
            + line(5, "a") + wideCell(5, 1, text: "中") + line(5, "b", col: 3)
            + wideCell(6, 0, text: "\u{3000}") + line(6, "ascii", col: 4)
            + wideLine(7, "斜体", Style(italic: true)) + wideLine(8, "太字", Style(bold: true))
            + wideLine(9, "粗斜", Style(bold: true, italic: true))
            + wideCell(10, 0, text: "→") + wideCell(10, 4, text: "★")
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            let painted = paintedPixels(cpu)
            XCTAssertGreaterThan(painted, 1000, "\(scale)x wide CJK CPU reference painted \(painted) pixels")
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(scale)x wide CJK max channel difference \(result.max)")
            XCTAssertGreaterThan(result.exact, 0.95, "\(scale)x wide CJK identical pixels \(result.exact)")
            XCTAssertFalse(composer.isSuspended, "\(scale)x wide CJK must not exhaust the atlas")
        }
    }

    /// Single-cell colour clusters at every validated backing scale. Each is one cell the composer can draw
    /// as a single unit: a plain emoji-presentation scalar, a text scalar promoted by VS16, a skin-tone
    /// modifier, a keycap sequence, narrow and wide, beside ASCII and beside a wide CJK cell.
    @MainActor func testColourEmojiFrameMatchesTheCpuRasterizerAtEveryValidatedScale() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let cells = line(0, "😀🙂🫠🧡") + line(1, "❤️⚠️✅☑️", Style(fg: [240, 180, 90]))
            + line(2, "👍🏽👋🏿👶🏻") + line(3, "#️⃣0️⃣a") + line(4, "x😀y")
            + wideLine(5, "😀🧡") + wideCell(6, 0, text: "👍🏽") + line(6, "z", col: 2)
            + wideCell(7, 0, text: "漢") + wideCell(7, 2, text: "⭐")
            + line(8, "™", Style(bold: true)) + line(9, "😀", Style(italic: true))
            + line(10, "\u{1F600}\u{0301}abc")
            + line(11, "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E007F}x")
            + [wire(11, 2, text: "\u{1F600}", Style(underline: true, strike: true, underlineColor: [90, 200, 90]))]
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (frame, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            XCTAssertGreaterThan(paintedPixels(cpu), 1000, "\(scale)x colour CPU reference painted \(paintedPixels(cpu)) pixels")
            XCTAssertFalse(frame.colourUploads.isEmpty, "\(scale)x colour clusters rasterised at least one tile")
            XCTAssertGreaterThan(composer.colourTiles, 0, "\(scale)x colour page grew")
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(scale)x colour max channel difference \(result.max)")
            XCTAssertGreaterThan(result.exact, 0.95, "\(scale)x colour identical pixels \(result.exact)")
            XCTAssertFalse(composer.isSuspended, "\(scale)x colour emoji must not exhaust either page")
        }
    }

    /// A dense field of colour clusters. With most of the grid painted, the identical-pixel fraction measures
    /// the tiles themselves rather than the background they sit in, so a wrong channel order, a flipped tile or
    /// a one-cell offset all fail here instead of hiding under a sparse screen's empty majority.
    @MainActor func testADenseColourEmojiFieldMatchesTheCpuRasterizer() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let glyphs = ["\u{1F600}", "\u{1F642}", "\u{1F9E1}", "\u{2764}\u{FE0F}", "\u{26A0}\u{FE0F}", "\u{2705}",
                      "\u{1F44D}\u{1F3FD}", "\u{1F44B}\u{1F3FF}", "#\u{FE0F}\u{20E3}", "0\u{FE0F}\u{20E3}",
                      "\u{2B50}", "\u{1FAE0}"]
        for scale: CGFloat in [1, 2] {
            var cells: [[Any]] = []
            for row in 0..<rows {
                let wide = row % 2 == 1
                var col = 0
                while col < cols {
                    let text = glyphs[(row * cols + col) % glyphs.count]
                    if wide, col + 1 < cols { cells += wideCell(row, col, text: text); col += 2 }
                    else { cells.append(wire(row, col, text: text)); col += 1 }
                }
            }
            let snapshot = try snapshot(cells: cells)
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (frame, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            let painted = paintedPixels(cpu)
            XCTAssertGreaterThan(painted, 10_000, "\(scale)x dense colour field painted \(painted) pixels")
            XCTAssertFalse(frame.colourUploads.isEmpty, "\(scale)x dense field rasterised colour tiles")
            XCTAssertFalse(composer.isSuspended, "\(scale)x a dozen distinct clusters cannot exhaust the colour page")
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(scale)x dense colour max channel difference \(result.max)")
            XCTAssertGreaterThan(result.exact, 0.95, "\(scale)x dense colour identical pixels \(result.exact)")
        }
    }

    /// Colour tiles are whole cell boxes packed on their own shelf, so a warm frame uploads nothing, a
    /// recreate frame uploads every tile exactly once, and no two tiles may claim the same region.
    @MainActor func testColourTilesAreUploadedOnceAndPackedDisjointly() throws {
        let composer = TextComposer()
        let cells = line(0, "\u{1F600}\u{1F642}\u{1F9E1}") + wideLine(1, "\u{2764}\u{FE0F}\u{2B50}")
            + line(2, "#\u{FE0F}\u{20E3}\u{1F44D}\u{1F3FD}")
        let snapshot = try snapshot(cells: cells)
        let first = try XCTUnwrap(compose(snapshot, composer: composer, damage: nil))
        XCTAssertGreaterThan(first.colourUploads.count, 0, "the first frame rasterises every distinct cluster")
        for upload in first.colourUploads {
            XCTAssertEqual(upload.pixels.count, upload.width * upload.height * 4, "a tile carries premultiplied BGRA")
            XCTAssertGreaterThan(upload.width, 0); XCTAssertGreaterThan(upload.height, 0)
            XCTAssertLessThanOrEqual(upload.x + upload.width, GlyphAtlas.textureSize)
            XCTAssertLessThanOrEqual(upload.y + upload.height, GlyphAtlas.textureSize)
        }
        assertColourDisjoint(first.colourUploads, entries: composer.colourTiles)
        for _ in 0..<10 {
            let again = try XCTUnwrap(compose(snapshot, composer: composer, damage: Set(0..<rows)))
            XCTAssertTrue(again.colourUploads.isEmpty, "a static emoji screen uploads nothing once warm")
            XCTAssertTrue(again.uploads.isEmpty, "a static emoji screen uploads no coverage either")
            XCTAssertFalse(again.resetAtlas)
        }
        // A layout change drops both pages; the recreate frame must re-upload every tile it re-packs.
        let resized = try XCTUnwrap(composer.compose(snapshot: snapshot, damage: nil, size: size, scale: 3,
                                                     fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                     appearance: .standard))
        XCTAssertTrue(resized.resetAtlas, "a backing-scale change recreates both atlas pages")
        XCTAssertTrue(resized.usesColourPage, "the resized frame still draws colour clusters")
        assertColourDisjoint(resized.colourUploads, entries: composer.colourTiles)
        // Dropping back to an emoji-free screen resets both pages, so the frame must not ask the presenter
        // for 16 MiB it will never sample.
        let plain = try XCTUnwrap(composer.compose(snapshot: try self.snapshot(cells: line(0, "ascii")), damage: nil,
                                                   size: size, scale: 1, fontName: "Menlo", fontSize: 13, cell: cell,
                                                   cjkFontName: "", appearance: .standard))
        XCTAssertTrue(plain.resetAtlas, "a scale change recreates both atlas pages")
        XCTAssertTrue(plain.colourUploads.isEmpty, "no colour cluster, no tile")
        XCTAssertFalse(plain.usesColourPage, "an emoji-free epoch must not allocate the colour page")
        XCTAssertEqual(composer.colourTiles, 0, "the reset dropped every colour entry")
    }

    /// What the colour page still refuses: a cluster the composer cannot draw as one unit, and one longer than
    /// the bounded scalar count. Refusal must not grow either page or burn a reset.
    func testRefusedColourClustersGrowNeitherAtlasPage() throws {
        let composer = TextComposer()
        _ = try XCTUnwrap(compose(try snapshot(cells: line(0, "\u{1F600}")), composer: composer, damage: nil))
        let entries = composer.atlasEntries, tiles = composer.colourTiles, resets = composer.atlasResets
        XCTAssertGreaterThan(tiles, 0, "the supported cluster opened the colour page")
        // The last is a hostile one-cell cluster: eight variation selectors keep it a single grapheme while
        // pushing it past the bounded scalar count, so the composer refuses it instead of rasterising it.
        let refused = ["\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F1EF}\u{1F1F5}", "\u{1F1FA}\u{200D}\u{1F1F8}",
                       "\u{1F600}\u{200D}",
                       "\u{1F600}" + String(repeating: "\u{FE0F}", count: TextEligibility.maxClusterScalars)]
        for text in refused {
            XCTAssertNil(compose(try snapshot(cells: line(0, text)), composer: composer, damage: nil), text)
            XCTAssertEqual(composer.atlasEntries, entries, text)
            XCTAssertEqual(composer.colourTiles, tiles, text)
            XCTAssertEqual(composer.atlasResets, resets, text)
            XCTAssertFalse(composer.isSuspended, text)
        }
    }

    /// The cursor draws over a colour tile exactly as it does over coverage: the tile carries its own colour,
    /// so the cursor band must not tint it and the translucent block must still match the CPU reference.
    @MainActor func testCursorOverColourEmojiMatchesTheCpuRasterizer() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let cells = line(2, "\u{1F600}ab", col: 3) + wideCell(2, 8, text: "\u{1F9E1}")
        for style in CursorStyle.allCases {
            var appearance = RenderAppearance.standard
            appearance.cursorStyle = style
            // Once over the narrow cluster and once over the wide one: the band must cover a two-column tile
            // without tinting it, and the block must still composite at its own opacity.
            for column in [3, 8] {
            let snapshot = try snapshot(cells: cells, cursor: ["row": 2, "col": column, "visible": true])
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "", appearance: appearance)
            let (_, gpu) = try render(snapshot, scale: 2, presenter: presenter, composer: composer, appearance: appearance)
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(style) col \(column) max channel difference \(result.max)")
            XCTAssertGreaterThan(result.exact, 0.95, "\(style) col \(column) identical pixels \(result.exact)")
            }
        }
    }

    /// The composer iterates raw cells, which is only valid while `GlyphClusters.merge` is the identity on an
    /// eligible frame. Pin the coupling from this side: for both of merge's triggers, a cell that could take
    /// part in a join must be refused. A third trigger added to merge without widening the refusal set fails here.
    func testEveryCellMergeWouldJoinIsRefusedByEligibility() throws {
        let bases = ["", "a", "\u{4E2D}", "\u{1F600}", "\u{2764}\u{FE0F}", "\u{1F44D}\u{1F3FD}", "#\u{FE0F}\u{20E3}"]
        var joins = 0
        // Trigger 1: a cell whose text ends in a ZWJ absorbs the next non-blank cell in its row.
        for base in bases {
            let pair = try cellPair(base + "\u{200D}", "\u{1F600}")
            guard GlyphClusters.merge(pair).count < pair.count else { continue }
            joins += 1
            XCTAssertNotNil(TextEligibility.unsupportedCell(pair[0]), "'\(base)' + ZWJ must be refused")
        }
        // Trigger 2: a regional indicator absorbs the next regional indicator.
        for value: UInt32 in 0x1F1E6...0x1F1FF {
            let indicator = String(UnicodeScalar(value)!)
            let pair = try cellPair(indicator, indicator)
            guard GlyphClusters.merge(pair).count < pair.count else { continue }
            joins += 1
            XCTAssertNotNil(TextEligibility.unsupportedCell(pair[0]),
                            "U+\(String(value, radix: 16, uppercase: true)) must be refused")
        }
        XCTAssertEqual(joins, bases.count + 26, "merge really would have joined every pair above")
    }

    /// Scrolling translates retained rows by whole cells; a colour tile's UVs travel with its row, so a
    /// translated emoji row must equal a full re-encode of the same snapshot and the CPU reference.
    @MainActor func testScrollTranslatesAColourEmojiRowAndMatchesFullEncoding() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let source = (0..<rows).map { $0 % 2 == 0 ? "\u{1F600} row \($0)" : "row \($0) \u{2764}\u{FE0F}" }
        let shifted = Array(source.dropFirst(2)) + ["new \u{1F9E1} ten", "new eleven \u{2B50}"]
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let initial = try snapshot(cells: source.enumerated().flatMap { line($0.offset, $0.element) },
                                       cursor: ["row": 4, "col": 2, "visible": true])
            let initialFrame = try XCTUnwrap(composer.compose(snapshot: initial, damage: nil, size: size, scale: scale,
                                                              fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                              appearance: .standard))
            XCTAssertFalse(initialFrame.colourUploads.isEmpty, "scale \(scale) rasterised colour tiles")
            try presenter.updateText(initialFrame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            let next = try snapshot(cells: shifted.enumerated().flatMap { line($0.offset, $0.element) },
                                    cursor: ["row": 3, "col": 1, "visible": true])
            let frame = try XCTUnwrap(composer.compose(snapshot: next, damage: [10, 11], size: size, scale: scale,
                                                       fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                       appearance: .standard, scroll: 2))
            XCTAssertEqual(composer.translatedRowCount, rows - 4, "scale \(scale)")
            try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            let actual = try presenter.renderOffscreen(width: bitmapSize(scale).width, height: bitmapSize(scale).height)

            let full = try XCTUnwrap(TextComposer().compose(snapshot: next, damage: nil, size: size, scale: scale,
                                                            fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                            appearance: .standard))
            try presenter.updateText(full, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            let expected = try presenter.renderOffscreen(width: bitmapSize(scale).width, height: bitmapSize(scale).height)
            XCTAssertEqual(actual, expected, "scale \(scale) a translated colour row matches a full atlas encode")
            let cpu = try GridRasterizer.make(snapshot: next, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            XCTAssertLessThanOrEqual(compare(cpu, actual).max, 2, "scale \(scale) matches the CPU rasterizer")
        }
    }

    /// Distinct colour clusters accumulate like distinct coverage colours: the entry cap must engage the
    /// bounded rebuild, and a recreate frame may upload none of the discarded attempt's tiles.
    @MainActor func testAtlasStaysBoundedUnderAColourClusterStorm() throws {
        let composer = TextComposer()
        var completed = 0
        for frame in 0..<12 {
            var cells: [[Any]] = []
            for row in 0..<rows {
                for col in 0..<cols {
                    let key = frame * rows * cols + row * cols + col
                    let fg = [key % 251, (key / 251) % 251, (key / 63_001) % 251]
                    let glyph = ["\u{1F600}", "\u{1F642}", "\u{1F9E1}", "\u{2B50}"][key % 4]
                    cells.append(self.wire(row, col, text: glyph, Style(fg: fg)))
                }
            }
            let result = composer.compose(snapshot: try snapshot(cells: cells), damage: nil, size: size, scale: 1,
                                          fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                          appearance: .standard)
            if result != nil { completed += 1 }
            XCTAssertLessThanOrEqual(composer.colourTiles, GlyphAtlas.maxColourEntries, "the colour entry cap holds")
            XCTAssertLessThanOrEqual(composer.atlasEntries, GlyphAtlas.maxEntries, "the coverage entry cap holds")
            if let result, result.resetAtlas {
                assertColourDisjoint(result.colourUploads, entries: composer.colourTiles)
                assertDisjoint(result.uploads, entries: composer.atlasEntries)
            }
        }
        XCTAssertEqual(completed, 12, "each current frame fits after old colour tiles are discarded")
        XCTAssertGreaterThan(composer.atlasResets, 1, "the entry cap engages the bounded rebuild path")
        XCTAssertLessThanOrEqual(GlyphAtlas.maxColourEntries, 4096, "the colour entry cap is bounded")
    }

    /// A face larger than its cell forces `placement` to shrink the ink, which exercises the two-column
    /// scale factor, the overflow slides and the mask clamp that a 13 pt face never reaches.
    @MainActor func testWideGlyphsThatMustShrinkToFitTwoColumnsMatchTheCpuRasterizer() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let snapshot = try snapshot(cells: wideLine(0, "鬱龘龜") + wideLine(1, "漢字", Style(fg: [240, 180, 90])))
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo",
                                              fontSize: 36, cellSize: cell, composition: "")
            presenter.clearColor = MetalPresenter.clearColor(for: RenderAppearance.standard.backgroundColor)
            let frame = try XCTUnwrap(composer.compose(snapshot: snapshot, damage: nil, size: size, scale: scale,
                                                       fontName: "Menlo", fontSize: 36, cell: cell, cjkFontName: "",
                                                       appearance: .standard), "\(scale)x shrunk wide glyph must compose")
            try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            let (width, height) = bitmapSize(scale)
            let gpu = try presenter.renderOffscreen(width: width, height: height)
            XCTAssertGreaterThan(paintedPixels(cpu), 0, "\(scale)x shrink CPU reference painted glyphs")
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(scale)x shrunk wide glyph max channel difference \(result.max)")
            XCTAssertGreaterThan(result.exact, 0.90, "\(scale)x shrunk wide glyph identical pixels \(result.exact)")
        }
    }

    /// A damaged row of wide cells must re-encode only that row and still produce exactly what a full
    /// encode of the same snapshot produces; wide masks are twice the area, so packing regressions and
    /// stale two-column UVs surface here first.
    @MainActor func testOnlyDirtyRowsWithWideCellsAreReEncoded() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        let base = (0..<rows).map { wideLine($0, "漢字日本語") }
        _ = try render(try snapshot(cells: base.flatMap { $0 }), scale: 2, presenter: presenter, composer: composer)
        var mutated = base
        mutated[3] = wideLine(3, "中文한글")
        let changed = try snapshot(cells: mutated.flatMap { $0 })
        let frame = try XCTUnwrap(compose(changed, composer: composer, damage: [3]))
        XCTAssertEqual(frame.dirtyRows, [3], "only the damaged row is re-encoded")
        let full = try XCTUnwrap(compose(changed, composer: TextComposer(), damage: nil))
        XCTAssertEqual(frame.content, [full.content[3]],
                       "the re-encoded wide row matches the same row from a full encode")
    }

    /// A column count other than one or two would write a mask of the wrong width into a real slot, so it
    /// is rejected rather than clamped.
    func testFittedEntryRejectsAColumnCountThatIsNotOneOrTwo() throws {
        let atlas = GlyphAtlas()
        let geometry = try XCTUnwrap(TextEligibility.geometry(size: size, scale: 2, cell: cell, fontName: "Menlo",
                                                              fontSize: 13, cols: cols, rows: rows))
        let face = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        for columns in [-1, 0, 3, 4] {
            XCTAssertNil(atlas.fittedEntry(style: 0, text: "漢", columns: columns,
                                           fg: [218, 226, 239], face: face, geometry: geometry),
                         "\(columns) columns is not a terminal width")
        }
        XCTAssertEqual(atlas.count, 0, "a rejected column count must not grow the atlas")
    }

    /// A wide lead and its spacer paint solid quads only, so there is no antialiasing to tolerate: the lead's
    /// two-column fill and the spacer's one-column repaint must land byte-identically on both paths.
    @MainActor func testWideCellFillsAndSelectionAreByteIdentical() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        // Blank wide cells carry no glyph, isolating the fill, selection and search passes.
        let cells = wideCell(0, 0, text: " ", Style(selected: true))
            + wideCell(1, 0, text: " ", Style(bg: [40, 60, 90]))
            + wideCell(2, 0, text: " ", Style(search: true, activeSearch: true))
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            XCTAssertEqual(compare(cpu, gpu).max, 0, "\(scale)x wide fills and selection must be byte-identical")
        }
    }

    /// One column left-aligns a glyph and shrinks ink wider than the cell; two columns centre it at full
    /// size. The masks therefore differ, and aliasing them would render the wrong shape after a width change.
    func testWideAndNarrowRenderingsOfTheSameScalarAreSeparateAtlasEntries() throws {
        let geometry = try XCTUnwrap(TextEligibility.geometry(size: size, scale: 2, cell: cell, fontName: "Menlo",
                                                              fontSize: 13, cols: cols, rows: rows))
        let face = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let fg: [UInt8] = [218, 226, 239]
        for wideFirst in [false, true] {
            let atlas = GlyphAtlas()
            var narrow: GlyphAtlas.Entry?, wide: GlyphAtlas.Entry?
            for columns in wideFirst ? [2, 1] : [1, 2] {
                guard case .entry(let entry)? = atlas.fittedEntry(style: 0, text: "漢", columns: columns,
                                                                  fg: fg, face: face, geometry: geometry) else {
                    return XCTFail("漢 must be fitted at \(columns) column(s)")
                }
                if columns == 2 { wide = entry } else { narrow = entry }
            }
            let narrowEntry = try XCTUnwrap(narrow), wideEntry = try XCTUnwrap(wide)
            XCTAssertFalse(narrowEntry.u == wideEntry.u && narrowEntry.v == wideEntry.v,
                           "column count must key the mask regardless of insertion order")
            XCTAssertGreaterThan(wideEntry.width, narrowEntry.width, "a two-column mask covers a wider box")
            XCTAssertEqual(atlas.count, 2)
            assertDisjoint(atlas.pending, entries: 2)
        }
    }

    /// Swift compares strings by canonical equivalence, so a CJK compatibility ideograph equals and hashes
    /// like its unified form while CoreText draws different ink for each. Keying masks by scalar keeps them apart.
    func testCanonicallyEquivalentIdeographsDoNotShareAnAtlasEntry() throws {
        XCTAssertEqual("\u{FA10}", "\u{585A}", "the compatibility form is the same Swift String as the unified one")
        let atlas = GlyphAtlas()
        let geometry = try XCTUnwrap(TextEligibility.geometry(size: size, scale: 2, cell: cell, fontName: "Menlo",
                                                              fontSize: 13, cols: cols, rows: rows))
        let face = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let fg: [UInt8] = [218, 226, 239]
        guard case .entry? = atlas.fittedEntry(style: 0, text: "\u{FA10}", columns: 2,
                                               fg: fg, face: face, geometry: geometry) else {
            return XCTFail("U+FA10 must be fitted")
        }
        guard case .entry? = atlas.fittedEntry(style: 0, text: "\u{585A}", columns: 2,
                                               fg: fg, face: face, geometry: geometry) else {
            return XCTFail("U+585A must be fitted")
        }
        XCTAssertEqual(atlas.count, 2, "equivalent strings must not share one mask")
        assertDisjoint(atlas.pending, entries: 2)
        // Two entries are not enough on their own: if the analysis cache aliased them, both would hold the
        // first codepoint's glyph. The coverage itself has to differ.
        let uploads = atlas.pending
        XCTAssertEqual(uploads.count, 2)
        XCTAssertNotEqual(uploads[0].coverage, uploads[1].coverage,
                          "each codepoint must rasterise its own glyph, not the cached equivalent's")
    }

    /// A full analysis cache stops taking new residents instead of refusing the glyph or evicting the hot
    /// set. Refusing would pin every later unseen glyph to the software rasterizer for the rest of the
    /// epoch, and clearing would oscillate once the repertoire exceeds the cap.
    func testAFullAnalysisCacheStillFitsLaterGlyphs() throws {
        let face = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let probe = "漢"
        XCTAssertTrue(GlyphAtlas().canFit(style: 0, text: probe, face: face),
                      "the probe glyph is fittable when cold")
        let atlas = GlyphAtlas()
        // Distinct ideographs below the probe's codepoint, so filling the cache never warms the probe.
        for offset in 0..<(GlyphAtlas.maxEntries + 16) {
            let scalar = try XCTUnwrap(Unicode.Scalar(0x4E00 + UInt32(offset)))
            _ = atlas.canFit(style: 0, text: String(scalar), face: face)
        }
        XCTAssertTrue(atlas.canFit(style: 0, text: probe, face: face),
                      "a full analysis cache must still analyse a later glyph")
    }

    /// The composer iterates raw cells, so a wide cell the CPU would absorb into a preceding cluster must
    /// never reach it. Absorption needs a ZWJ or regional-indicator lead, and every such lead is itself
    /// ineligible — that is the property keeping the two paths in agreement, so both halves are asserted.
    func testAClusterLeadRefusesTheFrameEvenWhenTheWideFollowerIsFittable() throws {
        let composer = TextComposer()
        _ = try XCTUnwrap(compose(try snapshot(cells: line(0, "x")), composer: composer, damage: nil))
        let entries = composer.atlasEntries, resets = composer.atlasResets
        XCTAssertNotNil(compose(try snapshot(cells: wideCell(0, 0, text: "中")), composer: TextComposer(), damage: nil),
                        "a lone wide scalar is drawable on its own")
        let absorbed = [wire(0, 0, text: "a\u{200D}"), wire(0, 1, text: "中", Style(wide: true)), wire(0, 2, text: "")]
        XCTAssertNil(compose(try snapshot(cells: absorbed), composer: composer, damage: nil),
                     "a ZWJ lead makes the whole frame ineligible, follower included")
        XCTAssertEqual(composer.atlasEntries, entries, "a refused frame must not grow the atlas")
        XCTAssertEqual(composer.atlasResets, resets)
    }

    /// The core emits a wide lead plus a blank spacer that inherits the lead's presentation. That shape is
    /// what makes the composer's raw-cell iteration safe, so it is checked against the real core.
    func testRealCoreWideCellsArriveAsALeadAndBlankSpacer() throws {
        let session = try TerminalSession(cols: 20, rows: 4, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}[1;1H\u{1b}[44m中文\u{1b}[0m"])
        let cells = try XCTUnwrap(try session.snapshot()).cells
        for text in ["中", "文"] {
            let lead = try XCTUnwrap(cells.first { $0.text == text }, "the core reports \(text)")
            XCTAssertTrue(lead.wide, "\(text) is two columns wide")
            let spacer = try XCTUnwrap(cells.first { $0.row == lead.row && $0.col == lead.col + 1 },
                                       "\(text) is followed by its spacer")
            XCTAssertEqual(spacer.text, "", "the spacer carries no glyph")
            XCTAssertFalse(spacer.wide, "the spacer is not itself wide")
            XCTAssertEqual(spacer.bg, lead.bg, "the spacer inherits the lead's background")
        }
    }

    /// A screen of CJK at rest must cost nothing after its first frame: a reset or upload per frame would be
    /// worse than the software rasterizer it replaced.
    func testAStableCjkScreenNeverThrashesTheAtlas() throws {
        let composer = TextComposer()
        let columns = Array(stride(from: 0, to: cols - 1, by: 2))
        var cells: [[Any]] = [], scalar: UInt32 = 0x4E00
        for row in 0..<rows {
            for column in columns {
                cells += wideCell(row, column, text: String(try XCTUnwrap(Unicode.Scalar(scalar))))
                scalar += 1
            }
        }
        let snapshot = try snapshot(cells: cells)
        let first = try XCTUnwrap(compose(snapshot, composer: composer, damage: nil))
        XCTAssertGreaterThan(first.uploads.count, 0, "the first frame rasterises the screen")
        XCTAssertFalse(composer.isSuspended, "one screen of CJK fits the atlas")
        let entries = composer.atlasEntries, resets = composer.atlasResets
        XCTAssertEqual(entries, columns.count * rows, "one mask per distinct glyph and none for the spacers")
        for _ in 0..<20 {
            let again = try XCTUnwrap(compose(snapshot, composer: composer, damage: Set(0..<rows)))
            XCTAssertTrue(again.uploads.isEmpty, "a static CJK screen uploads nothing once warm")
            XCTAssertFalse(again.resetAtlas)
            XCTAssertEqual(composer.atlasEntries, entries)
            XCTAssertEqual(composer.atlasResets, resets)
        }
    }

    func testColorAndClusterContentFallsBackWithoutGrowingTheAtlas() throws {
        let composer = TextComposer()
        _ = try XCTUnwrap(compose(try snapshot(cells: line(0, "x")), composer: composer, damage: nil))
        let entries = composer.atlasEntries, resets = composer.atlasResets
        // A single-cell colour cluster now draws from the colour page, even with a combining mark on it. What
        // still refuses: a ZWJ or a regional indicator, either of which could take part in a
        // `GlyphClusters.merge` join, and a multi-scalar cell with no colour scalar in it at all.
        for text in ["🇺🇸", "👨\u{200d}👩\u{200d}👧", "🇺", "\u{200d}", "e\u{0301}"] {
            XCTAssertNil(compose(try snapshot(cells: line(0, text)), composer: composer, damage: nil), text)
            XCTAssertEqual(composer.atlasEntries, entries, text)
            XCTAssertEqual(composer.atlasResets, resets, text)
        }
        let color = TextComposer()
        XCTAssertNil(color.compose(snapshot: try snapshot(cells: line(0, "⚠")), damage: nil, size: size, scale: 2,
                                   fontName: "Apple Color Emoji", fontSize: 13, cell: cell, cjkFontName: "", appearance: .standard),
                     "a resolved color font cannot use the single-channel atlas")
        XCTAssertEqual(color.atlasEntries, 0)
    }

    @MainActor func testSingleUnderlineAndStrikeMatchTheCpuRasterizerAtEveryValidatedScale() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let cells = line(0, "gjpqy", Style(underline: true, underlineColor: [240, 80, 80]))
            + line(1, "éⅢ", Style(underline: true))
            + line(2, "strike", Style(strike: true, underlineColor: [90, 200, 90]))
            + line(3, "both", Style(underline: true, strike: true))
            + line(4, "│█", Style(underline: true))
            + [wire(5, 0, text: "", Style(underline: true)), wire(5, 1, text: " ", Style(strike: true)),
               wire(5, 2, text: "\u{2800}", Style(underline: true))]
        let snapshot = try snapshot(cells: cells, cursor: ["row": 0, "col": 0, "visible": true])
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(scale)x decorated max channel difference \(result.max)")
            XCTAssertGreaterThan(result.exact, 0.90, "\(scale)x decorated identical pixels \(result.exact)")
        }
    }

    func testComplexUnderlineStylesRemainOnTheCpuPathWithoutGrowingTheAtlas() throws {
        let composer = TextComposer()
        _ = try XCTUnwrap(compose(try snapshot(cells: line(0, "x")), composer: composer, damage: nil))
        let entries = composer.atlasEntries, resets = composer.atlasResets
        for style in UInt8(2)...5 {
            let cells = line(0, "x", Style(underline: true, underlineStyle: style))
            XCTAssertNil(compose(try snapshot(cells: cells), composer: composer, damage: nil), "style \(style)")
            XCTAssertEqual(composer.atlasEntries, entries, "style \(style)")
            XCTAssertEqual(composer.atlasResets, resets, "style \(style)")
        }
    }

    /// Box and block geometry is cached as colour-independent coverage, including junctions and complementary halves.
    @MainActor func testGeometricFrameMatchesTheCpuRasterizerAtEveryValidatedScale() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let cells = line(0, "╭──┬──╮") + line(1, "│ ▀▄▌▐│", Style(fg: [90, 180, 240]))
            + line(2, "├─█▓▒░┤", Style(bold: true)) + line(3, "╰──┴──╯")
            + line(4, "╱╲╳╬╪╫", Style(fg: [240, 180, 90]))
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 1, "\(scale)x geometric max channel difference \(result.max)")
        }
    }

    /// Braille circles use ordinary antialiasing rather than colour-dependent font smoothing.
    @MainActor func testBrailleFrameMatchesTheCpuRasterizerAtEveryValidatedScale() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let cells = line(0, "⠀⠁⠃⠇⡿⣿") + line(1, "⠿⠋⠙⠸⣿⣷⣦", Style(fg: [120, 220, 130]))
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            XCTAssertLessThanOrEqual(compare(cpu, gpu).max, 2, "\(scale)x braille max channel difference")
        }
    }

    /// ANSI colours, custom cell backgrounds, selection and both find highlights are drawn by the GPU path.
    @MainActor func testAnsiColoursBackgroundsAndHighlightsMatchTheCpuRasterizer() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let cells = line(0, "red", Style(fg: [255, 80, 70], bg: [40, 20, 20]))
            + line(0, "green", col: 4, Style(fg: [120, 220, 130], bg: [10, 35, 15]))
            + line(1, "selected", Style(selected: true))
            + line(2, "found", Style(search: true))
            + line(3, "active", Style(activeSearch: true))
            + line(4, "plain")
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(scale)x max channel difference \(result.max)")
        }
    }

    /// Every cursor style is a GPU quad set: outline, block, bar and underline must match the rasterizer.
    @MainActor func testCursorStylesMatchTheCpuRasterizer() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        for style in CursorStyle.allCases {
            var appearance = RenderAppearance.standard
            appearance.cursorStyle = style
            let snapshot = try snapshot(cells: line(2, "x", col: 3), cursor: ["row": 2, "col": 3, "visible": true])
            for scale: CGFloat in [2, 3] {
                let composer = TextComposer()
                let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                                  cellSize: cell, composition: "", appearance: appearance)
                let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer, appearance: appearance)
                let result = compare(cpu, gpu)
                XCTAssertLessThanOrEqual(result.max, 2, "\(style) at \(scale)x max channel difference \(result.max)")
            }
        }
    }

    /// A non-default appearance (theme background, cursor and selection colours) is converted the same way the
    /// CPU bitmaps store it, so the GPU clear and fills stay byte-identical.
    @MainActor func testThemeAppearanceMatchesTheCpuRasterizer() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        var appearance = RenderAppearance.standard
        appearance.background = [22, 24, 29]
        appearance.foreground = [230, 232, 240]
        appearance.selection = [70, 100, 150]
        appearance.cursor = [250, 200, 90]
        appearance.cursorStyle = .bar
        let snapshot = try snapshot(cells: line(1, "theme", col: 1, Style(selected: true)) + line(3, "tail", col: 2),
                                    cursor: ["row": 4, "col": 0, "visible": true])
        let composer = TextComposer()
        let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                          cellSize: cell, composition: "", appearance: appearance)
        let (_, gpu) = try render(snapshot, scale: 2, presenter: presenter, composer: composer, appearance: appearance)
        let result = compare(cpu, gpu)
        XCTAssertLessThanOrEqual(result.max, 2, "max channel difference \(result.max)")
    }

    /// Styled faces are separate CoreText fonts, so bold, italic and bold-italic text need their own masks and
    /// their own equivalence check at every validated scale.
    @MainActor func testBoldItalicAndBoldItalicTextMatchTheCpuRasterizer() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let cells = line(0, "bold text", Style(bold: true))
            + line(1, "italic text", Style(italic: true))
            + line(2, "both faces", Style(bold: true, italic: true))
            + line(3, "plain text")
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer)
            let result = compare(cpu, gpu)
            XCTAssertLessThanOrEqual(result.max, 2, "\(scale)x max channel difference \(result.max)")
        }
    }

    /// Background, selection and find fills are solid quads, so they must land on exactly the bitmap's bytes.
    @MainActor func testSolidCellFillsAreByteIdentical() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        var appearance = RenderAppearance.standard
        appearance.background = [18, 20, 26]
        appearance.selection = [64, 96, 148]
        let cells = [
            wire(0, 0, text: "", Style(bg: [60, 80, 120])),
            wire(0, 2, text: "", Style(bg: [60, 80, 120])),
            wire(0, 4, text: "", Style(selected: true)),
            wire(1, 0, text: "", Style(search: true)),
            wire(1, 2, text: "", Style(activeSearch: true)),
            wire(2, 0, text: "", Style(bg: [40, 20, 20])),
            wire(2, 3, text: "", Style(bg: [255, 255, 255])),
            // Juxtaposed fills must not bleed into one another.
            wire(3, 0, text: "", Style(bg: [10, 200, 30])),
            wire(3, 1, text: "", Style(bg: [200, 10, 30]))
        ]
        let snapshot = try snapshot(cells: cells)
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo",
                                              fontSize: 13, cellSize: cell, composition: "", appearance: appearance)
            let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer,
                                      appearance: appearance)
            let result = compare(cpu, gpu)
            XCTAssertEqual(result.max, 0, "\(scale)x: solid cell fills must be byte-identical")
            XCTAssertGreaterThan(paintedPixels(cpu), 0, "\(scale)x: the fills actually paint")
        }
    }

    /// Cursor bands are quads too. `bar` and `underline` are exact at every scale; `block` is a 0.55 alpha blend
    /// and `outline` is a stroked path whose four corners are antialiased at 1x, so those may differ by one step.
    @MainActor func testCursorBandsMatchTheCpuRasterizer() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        for style in CursorStyle.allCases {
            var appearance = RenderAppearance.standard
            appearance.cursor = [250, 200, 90]
            appearance.cursorStyle = style
            let snapshot = try snapshot(cells: [], cursor: ["row": 3, "col": 1, "visible": true])
            for scale: CGFloat in [1, 2, 3] {
                let composer = TextComposer()
                let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: scale, fontName: "Menlo",
                                                  fontSize: 13, cellSize: cell, composition: "", appearance: appearance)
                let (_, gpu) = try render(snapshot, scale: scale, presenter: presenter, composer: composer,
                                          appearance: appearance)
                let result = compare(cpu, gpu)
                switch style {
                case .bar, .underline:
                    XCTAssertEqual(result.max, 0, "\(style) at \(scale)x must be byte-identical")
                case .outline:
                    // A 1 pt stroke only exposes its join antialiasing at 1x; the bands themselves are exact.
                    XCTAssertLessThanOrEqual(result.max, 1, "\(style) at \(scale)x")
                    XCTAssertGreaterThan(result.exact, 0.999, "\(style) at \(scale)x: only corners may differ")
                case .block:
                    // A translucent fill rounds one step apart from CoreGraphics' blend. The band still has to
                    // cover exactly the cursor cell: every difference must sit inside it.
                    XCTAssertLessThanOrEqual(result.max, 1, "\(style) at \(scale)x")
                    let diff = differences(cpu, gpu)
                    let band = CGRect(x: (GridRasterizer.margin + cell.width) * scale, y: (GridRasterizer.margin + 3 * cell.height) * scale,
                                      width: cell.width * scale, height: cell.height * scale)
                    XCTAssertLessThanOrEqual(diff.count, Int(cell.width * cell.height * scale * scale),
                                             "\(style) at \(scale)x: only the band itself may differ")
                    if let box = diff.box {
                        XCTAssertTrue(band.contains(box), "\(style) at \(scale)x: differences stay in the cursor cell")
                    }
                }
                XCTAssertGreaterThan(paintedPixels(cpu), 0, "\(style) at \(scale)x: the cursor paints")
            }
        }
    }

    /// The composer's per-row bound is the presenter's buffer stride: a fill, glyph, underline and strike in
    /// every column, plus all four cursor bands, must fit without truncation.
    @MainActor func testAWorstCaseRowFitsTheInstanceCapacity() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let capacity = MetalPresenter.textRowCapacity(cols: cols)
        var cells: [[Any]] = []
        for col in 0..<cols {
            cells.append(wire(0, col, text: "X", Style(bg: [30, 30, 30], selected: col % 2 == 0, underline: true, strike: true)))
        }
        let snapshot = try snapshot(cells: cells, cursor: ["row": 0, "col": cols - 1, "visible": true])
        let frame = try XCTUnwrap(compose(snapshot, composer: TextComposer(), damage: nil))
        XCTAssertEqual(frame.content[0].count, capacity, "the worst-case row uses exactly the stated capacity")
        try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        // One instance beyond the capacity is a programming error, not something to truncate silently.
        let overflowing = TextFrame(rows: 1, dirtyRows: [0],
                                    content: [Array(repeating: .zero, count: capacity + 1)],
                                    uploads: [], colourUploads: [], usesColourPage: false, resetAtlas: true)
        XCTAssertThrowsError(try presenter.updateText(overflowing, grid: GridGeometry(cols: cols, rows: 1, cell: cell, scale: 2)),
                             "a row that does not fit must fail over, never drop instances")
    }

    /// A frame drawn by another path (an image, a CJK line) must not invalidate masks the composer still caches:
    /// returning to the atlas reuses them, so the texture has to survive that detour.
    @MainActor func testReturningToTheAtlasAfterABitmapFrameKeepsEveryGlyph() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        let snapshot = try snapshot(cells: line(0, "atlas again") + line(1, "second row"))
        let (_, first) = try render(snapshot, scale: 2, presenter: presenter, composer: composer)
        // A CPU bitmap frame takes over, exactly as a CJK or image frame would.
        let bitmap = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                             cellSize: cell, composition: "")
        try presenter.update(bitmap: bitmap, damage: nil)
        XCTAssertFalse(presenter.textMode)
        // Back on the atlas: the composer re-rasterises nothing, so every mask must still be in the texture.
        let frame = try XCTUnwrap(compose(snapshot, composer: composer, damage: nil))
        XCTAssertFalse(frame.resetAtlas, "the layout did not change")
        XCTAssertTrue(frame.uploads.isEmpty, "cached masks are not rasterised again")
        try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        let again = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        XCTAssertEqual(again, first, "returning to the atlas keeps every glyph")
    }

    @MainActor func testDiscardedAtlasFrameDoesNotLoseGlyphsOnNextHandoff() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        let initial = try snapshot(cells: line(0, "aaaa"))
        _ = try render(initial, scale: 2, presenter: presenter, composer: composer)
        let next = try snapshot(cells: line(0, "ZZZZ") + line(1, "aaaa"))
        let discarded = try XCTUnwrap(composer.compose(snapshot: next, damage: [0, 1], size: size, scale: 2,
                                                       fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                       appearance: .standard, deferPublication: true))
        XCTAssertFalse(discarded.uploads.isEmpty, "the skipped handoff held a new glyph")

        let (recovered, gpu) = try render(next, scale: 2, presenter: presenter, composer: composer, damage: [1])
        XCTAssertEqual(recovered.dirtyRows.count, rows)
        XCTAssertEqual(composer.eligibilityScannedRows, rows, "no-scroll recovery also forces a full content scan")
        let cpu = try GridRasterizer.make(snapshot: next, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                          cellSize: cell, composition: "")
        XCTAssertLessThanOrEqual(compare(cpu, gpu).max, 2, "the recovered frame shows the new glyph in row 0")
    }

    // MARK: Buffer lifetime

    /// A frame submitted to the GPU keeps reading its instance buffer until it completes, so the next upload must
    /// publish a different buffer instead of editing the one in flight, and the result must still be complete.
    @MainActor func testInFlightFrameIsNeverRewritten() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        let grid = GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2)
        func snapshotOf(_ text: [String]) throws -> Snapshot {
            try snapshot(cells: text.enumerated().flatMap { line($0.offset, $0.element) })
        }
        var lines = (0..<rows).map { "row \($0)" }
        let firstSnapshot = try snapshotOf(lines)
        try presenter.updateText(try XCTUnwrap(compose(firstSnapshot, composer: composer, damage: nil)), grid: grid)
        let idleBuffer = presenter.textBufferIdentity
        XCTAssertEqual(presenter.textBufferCount, 1)

        // A real frame now blocks on the GPU while it still samples the current instance buffer.
        let held = try presenter.holdFrameInFlight()
        defer { held.release(); held.command.waitUntilCompleted() }
        XCTAssertEqual(presenter.pendingFrameCount, 1)

        lines[5] = "replaced row"
        let secondSnapshot = try snapshotOf(lines)
        let partial = try XCTUnwrap(compose(secondSnapshot, composer: composer, damage: [5]))
        try presenter.updateText(partial, grid: grid)

        XCTAssertNotEqual(presenter.textBufferIdentity, idleBuffer, "a busy GPU gets a published replacement buffer")
        XCTAssertEqual(presenter.textFullUploads, 1, "the busy frame took the full-copy path")
        XCTAssertLessThanOrEqual(presenter.textBufferCount, 3, "at most one draw buffer plus the bounded pool")

        held.release()
        held.command.waitUntilCompleted()
        waitUntilIdle(presenter)
        // Every row is current, not just the damaged one, because the replacement was built from the CPU mirror.
        let cpu = try GridRasterizer.make(snapshot: secondSnapshot, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                          cellSize: cell, composition: "")
        let gpu = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        XCTAssertLessThanOrEqual(compare(cpu, gpu).max, 2, "the published buffer holds the whole frame")

        // With the GPU idle again the cheap path returns: same buffer, one row written.
        let idleIdentity = presenter.textBufferIdentity
        let rowsBefore = presenter.textRowUploads
        lines[2] = "another row"
        let thirdFrame = try XCTUnwrap(compose(try snapshotOf(lines), composer: composer, damage: [2]))
        try presenter.updateText(thirdFrame, grid: grid)
        XCTAssertEqual(presenter.textBufferIdentity, idleIdentity, "an idle GPU keeps its buffer")
        XCTAssertEqual(presenter.textRowUploads - rowsBefore, 1, "only the damaged row is written")
        XCTAssertEqual(presenter.textFullUploads, 1, "no extra full copy once the GPU drained")
    }

    // MARK: CPU fall-through

    /// After atlas frames the CPU bitmap is stale, so a fall-through must repaint every row even when the core
    /// reported partial damage.
    @MainActor func testCpuFallThroughAfterAtlasFramesShowsCompleteContent() throws {
        let stale = try snapshot(cells: line(6, "old text"))
        let current = try snapshot(cells: line(6, "new text") + line(1, "changed"))
        let full = try GridRasterizer.make(snapshot: current, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                           cellSize: cell, composition: "")
        let plan = RenderReuse.plan(damage: [1], scroll: 0, layered: false, tryText: true,
                                    previousLayered: false, previousText: true)
        XCTAssertNil(plan.cpuDamage, "the CPU bitmap is stale after an atlas frame")
        XCTAssertEqual(plan.textDamage, [1], "the composer still applies its partial row")

        let recovered = GridRasterizer()
        _ = try recovered.render(snapshot: stale, damage: nil, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                 cellSize: cell, composition: "")
        let frame = try recovered.render(snapshot: current, damage: plan.cpuDamage, scroll: plan.cpuScroll, size: size,
                                         scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        XCTAssertEqual(bytes(frame.context), bytes(full), "a fall-through after atlas frames repaints every row")

        // Control: the partial damage the old code passed would have kept the atlas frame's row 6 on screen.
        let control = GridRasterizer()
        _ = try control.render(snapshot: stale, damage: nil, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                               cellSize: cell, composition: "")
        let staleFrame = try control.render(snapshot: current, damage: [1], scroll: 0, size: size, scale: 2,
                                            fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        XCTAssertNotEqual(bytes(staleFrame.context), bytes(full), "partial damage on a stale bitmap is the defect")
    }

    /// The reuse plan in tabular form: which damage each retained renderer may trust.
    func testReusePlanDecidesDamagePerPath() {
        func plan(_ damage: Set<Int>?, _ scroll: Int, layered: Bool = false, eligible: Bool = true,
                  previousLayered: Bool = false, previousText: Bool = false) -> RenderReuse {
            RenderReuse.plan(damage: damage, scroll: scroll, layered: layered, tryText: eligible,
                             previousLayered: previousLayered, previousText: previousText)
        }
        // Steady CPU frames keep partial damage and may move scrolled rows.
        XCTAssertEqual(plan([3], 0, eligible: false).cpuDamage, [3])
        XCTAssertEqual(plan([3], 2, eligible: false).cpuScroll, 2)
        // The first atlas frame needs every row from the composer but leaves the CPU bitmap current.
        XCTAssertNil(plan([3], 0).textDamage)
        XCTAssertEqual(plan([3], 0).cpuDamage, [3])
        // Steady atlas frames stay incremental on both sides.
        XCTAssertEqual(plan([3], 0, previousText: true).textDamage, [3])
        XCTAssertNil(plan([3], 0, previousText: true).cpuDamage, "the CPU bitmap is stale after an atlas frame")
        // An atlas scroll keeps final-coordinate damage for selective re-encoding and forbids a bitmap row move.
        XCTAssertEqual(plan([3], 2, previousText: true).textDamage, [3])
        XCTAssertNil(plan([3], 2, previousText: true).cpuDamage)
        XCTAssertEqual(plan([3], 2, previousText: true).cpuScroll, 0)
        // Layered frames repaint fully on a scroll and after a path change.
        XCTAssertNil(plan([3], 1, layered: true, eligible: false, previousLayered: true).cpuDamage)
        XCTAssertNil(plan([3], 0, layered: true, eligible: false, previousLayered: false).cpuDamage)
        XCTAssertEqual(plan([3], 0, layered: true, eligible: false, previousLayered: true).cpuDamage, [3])
        // Leaving the atlas for a non-eligible frame (CJK, suspension, atlas refusal) still repaints fully.
        XCTAssertNil(plan([3], 0, eligible: false, previousText: true).cpuDamage)
    }

    // MARK: Fallback decisions

    /// The content the atlas does not reproduce pixel-for-pixel keeps the software path, and `compose` refuses it
    /// rather than dropping cells.
    func testUnsupportedContentFallsBackToTheSoftwarePath() throws {
        func fallback(_ cells: [[Any]], composition: String = "", images: [ImagePlacement] = []) throws -> TextFallback? {
            let snapshot = try snapshot(cells: cells, images: images)
            return TextEligibility.fallback(snapshot: snapshot, composition: composition, size: size, scale: 2, cell: cell,
                                            fontName: "Menlo", fontSize: 13)
        }
        XCTAssertNil(try fallback(line(0, "plain ascii")), "ordinary text is eligible")
        XCTAssertNil(try fallback([wire(0, 0, text: " ")]), "a space is eligible without scalar inspection")
        XCTAssertNil(try fallback([wire(0, 0, text: "~")]), "the last printable ASCII byte is eligible")
        XCTAssertEqual(try fallback([wire(0, 0, text: String(UnicodeScalar(0x1f)!))]), .nonASCII)
        XCTAssertEqual(try fallback([wire(0, 0, text: String(UnicodeScalar(0x7f)!))]), .nonASCII)
        XCTAssertNil(try fallback([wire(0, 0, text: "█")]), "block geometry is eligible")
        XCTAssertNil(try fallback([wire(0, 0, text: "⠀")]), "blank braille is eligible without an atlas tile")
        XCTAssertNil(try fallback(line(0, "│")), "box geometry is eligible")
        XCTAssertNil(try fallback(line(0, "漢字", Style(wide: true))), "wide CJK is fitted into a two-column box")
        XCTAssertEqual(try fallback([wire(0, 0, text: "e\u{0301}")]), .nonASCII, "combining text keeps the software path")
        XCTAssertEqual(try fallback([wire(0, 0, text: "👨‍👩‍👧")]), .nonASCII, "emoji keeps the software path")
        XCTAssertNil(try fallback([wire(0, 0, text: "│")]), "box drawing uses geometric coverage, not a font glyph")
        for style in UInt8(2)...5 {
            XCTAssertEqual(try fallback(line(0, "und", Style(underline: true, underlineStyle: style))), .decoratedCell,
                           "underline style \(style) keeps the CPU path")
        }
        XCTAssertNil(try fallback([wire(0, 0, text: "中", Style(wide: true))]), "a wide scalar is fitted like a narrow one")
        XCTAssertEqual(try fallback([wire(0, 0, text: "中", Style(underline: true, wide: true))]), .wideCell,
                       "a wide decoration stays on the CPU path until it is separately qualified")
        XCTAssertEqual(try fallback([wire(0, 0, text: "中", Style(strike: true, wide: true))]), .wideCell,
                       "a wide strikethrough stays on the CPU path")
        // SGR-8 hides the glyph but keeps the decoration, so the blank-text return must not run first.
        XCTAssertEqual(try fallback([wire(0, 0, text: " ", Style(underline: true, wide: true))]), .wideCell,
                       "an invisible wide lead still carries its underline")
        XCTAssertEqual(try fallback([wire(0, 0, text: "", Style(strike: true, wide: true))]), .wideCell,
                       "an invisible wide lead still carries its strikethrough")
        XCTAssertEqual(try fallback([wire(0, 0, text: "中\u{0301}", Style(wide: true))]), .wideCell,
                       "a combining mark on a wide base stays on the CPU path")
        XCTAssertEqual(try fallback([wire(0, 0, text: "A", Style(wide: true))]), .wideCell,
                       "a wide cell holding printable ASCII stays on the CPU path")
        // Width is decided before the geometric test: a wide box glyph would rasterise a one-column
        // tile that the instance then stretches across two columns.
        XCTAssertEqual(try fallback([wire(0, 0, text: "█", Style(wide: true))]), .wideCell, "wide geometry keeps the CPU path")
        XCTAssertNil(try fallback([wire(0, 0, text: "😀", Style(wide: true))]),
                     "a single-cell colour cluster fits even when it is marked wide")
        XCTAssertNil(try fallback([wire(0, 0, text: "😀", Style(underline: true, strike: true))]),
                     "a narrow colour cell carries its single underline and strikethrough from the atlas")
        XCTAssertEqual(try fallback([wire(0, 0, text: "😀", Style(underline: true, wide: true))]), .wideCell,
                       "a decorated wide colour cell keeps the CPU path like any other decorated wide cell")
        XCTAssertEqual(try fallback([wire(0, 0, text: "👨\u{200d}👩\u{200d}👧")]), .nonASCII,
                       "a ZWJ cluster the composer cannot draw as one unit keeps the CPU path")
        XCTAssertEqual(try fallback([wire(0, 0, text: "│", Style(underline: true, underlineStyle: 2))]), .decoratedCell,
                       "decorated geometry keeps the CPU path")
        XCTAssertEqual(try fallback(line(0, "x"), composition: "ab"), .composition, "IME composition keeps the CPU path")
        XCTAssertEqual(try fallback(line(0, "x"), images: [placement(id: 1)]), .images,
                       "Kitty images keep the layered Metal path")

        // Fractional geometry cannot be blitted on integer pixels, so it is not eligible either.
        let plain = try snapshot(cells: line(0, "x"))
        XCTAssertEqual(TextEligibility.fallback(snapshot: plain, composition: "", size: size, scale: 1.5, cell: cell,
                                                fontName: "Menlo", fontSize: 13), .geometry, "a fractional backing scale")
        XCTAssertEqual(TextEligibility.fallback(snapshot: plain, composition: "",
                                                size: CGSize(width: size.width + 0.25, height: size.height), scale: 2,
                                                cell: cell, fontName: "Menlo", fontSize: 13), .geometry,
                       "a fractional bitmap width")
        // Composition also refuses at the composer, which is the only caller that can drop cells.
        let composer = TextComposer()
        XCTAssertNil(composer.compose(snapshot: try snapshot(cells: [wire(0, 0, text: "👨‍👩‍👧")]), damage: nil, size: size,
                                      scale: 2, fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                      appearance: .standard), "an emoji cluster must not be silently drawn as blanks")
    }

    func testPrevalidatedGeometryCannotBypassContentEligibility() throws {
        let unsupported = try snapshot(cells: line(0, "漢字", Style(wide: true)) + [wire(1, 0, text: "e\u{0301}")])
        let geometry = try XCTUnwrap(TextEligibility.geometry(size: size, scale: 2, cell: cell, fontName: "Menlo", fontSize: 13,
                                                              cols: cols, rows: rows))
        XCTAssertNil(TextComposer().compose(snapshot: unsupported, damage: nil, size: size, scale: 2,
                                            fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                            appearance: .standard, prevalidated: geometry),
                     "a supplied geometry only skips layout work, never content validation")
    }

    func testIncrementalEligibilityRechecksOnlyDirtyRows() throws {
        let composer = TextComposer()
        let source = (0..<rows).map { "row \($0)" }
        let initial = try snapshot(cells: source.enumerated().flatMap { line($0.offset, $0.element) })
        _ = try XCTUnwrap(compose(initial, composer: composer, damage: nil))
        XCTAssertEqual(composer.eligibilityScannedRows, rows)
        let changed = try snapshot(cells: line(0, "changed") + (1..<rows).flatMap { line($0, source[$0]) })
        _ = try XCTUnwrap(compose(changed, composer: composer, damage: [0]))
        XCTAssertEqual(composer.eligibilityScannedRows, 1)
        _ = try XCTUnwrap(compose(changed, composer: composer, damage: []))
        XCTAssertEqual(composer.eligibilityScannedRows, 0, "cursor-only damage needs no content scan")
    }

    func testDirtyUnsupportedCellsInvalidateEligibilityAndFullDamageRecovers() throws {
        let unsupported = [
            [wire(3, 0, text: "e\u{0301}")], [wire(3, 0, text: "👨‍👩‍👧")], [wire(3, 0, text: "\u{1F1EF}\u{1F1F5}")],
            [wire(3, 0, text: "中", Style(underline: true, wide: true))],
            line(3, "und", Style(underline: true, underlineStyle: 2)),
            line(3, "gone", Style(underline: true, underlineStyle: 5)),
        ]
        let source = (0..<rows).map { "row \($0)" }
        for changedRow in unsupported {
            let composer = TextComposer()
            let initial = try snapshot(cells: source.enumerated().flatMap { line($0.offset, $0.element) })
            _ = try XCTUnwrap(compose(initial, composer: composer, damage: nil))
            let cells = (0..<rows).flatMap { $0 == 3 ? changedRow : line($0, source[$0]) }
            let unsupportedSnapshot = try snapshot(cells: cells)
            XCTAssertNil(compose(unsupportedSnapshot, composer: composer, damage: [3]))
            XCTAssertEqual(composer.eligibilityScannedRows, 1, "only the changed row is inspected before refusal")
            XCTAssertNil(compose(unsupportedSnapshot, composer: composer, damage: [0]),
                         "an unrelated update cannot revive the certificate while unsupported content remains")
            _ = try XCTUnwrap(compose(initial, composer: composer, damage: nil))
            XCTAssertEqual(composer.eligibilityScannedRows, rows, "returning from CPU fallback rechecks the whole grid")
        }
    }

    func testScrollAndReleaseCannotReuseEligibilityCertificates() throws {
        let composer = TextComposer()
        let source = (0..<rows).map { "row \($0)" }
        let initial = try snapshot(cells: source.enumerated().flatMap { line($0.offset, $0.element) })
        _ = try XCTUnwrap(compose(initial, composer: composer, damage: nil))
        let shifted = try snapshot(cells: (1..<rows).flatMap { line($0 - 1, $0 == 1 ? "e\u{0301}" : source[$0]) }
            + line(rows - 1, "new"))
        XCTAssertNil(composer.compose(snapshot: shifted, damage: [rows - 1], size: size, scale: 2,
                                      fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                      appearance: .standard, scroll: 1),
                     "scroll must find unsupported content in a moved row even when only the exposed row is dirty")
        XCTAssertEqual(composer.eligibilityScannedRows, 1)
        _ = try XCTUnwrap(compose(initial, composer: composer, damage: nil))
        composer.releaseFrames()
        _ = try XCTUnwrap(compose(initial, composer: composer, damage: []))
        XCTAssertEqual(composer.eligibilityScannedRows, rows, "release invalidates the content certificate")
    }

    func testGlobalFallbackInvalidatesEligibilityBeforeTheNextCompose() throws {
        let composer = TextComposer()
        let initial = try snapshot(cells: line(0, "plain"))
        _ = try XCTUnwrap(compose(initial, composer: composer, damage: nil))
        let unsupported = try snapshot(cells: [wire(0, 0, text: "👨‍👩‍👧")], images: [placement(id: 1)])
        XCTAssertNil(compose(unsupported, composer: composer, damage: []), "images take the layered path first")
        let withoutImages = try snapshot(cells: [wire(0, 0, text: "👨‍👩‍👧")])
        XCTAssertNil(compose(withoutImages, composer: composer, damage: []),
                     "the next content check cannot reuse eligibility from before the image frame")
        XCTAssertEqual(composer.eligibilityScannedRows, 1)
    }

    func testCachedFontMetricsMatchFreshGeometry() throws {
        for fontName in ["Menlo", "Courier New"] {
            for fontSize in [CGFloat(13), 17.25] {
                let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
                let descent = CTFontGetDescent(font), xHeight = CTFontGetXHeight(font)
                for scale in [CGFloat(1), 2, 3] {
                    let fresh = TextEligibility.geometry(size: size, scale: scale, cell: cell, fontName: fontName,
                                                         fontSize: fontSize, cols: cols, rows: rows)
                    let cached = TextEligibility.geometry(size: size, scale: scale, cell: cell, fontName: fontName,
                                                          fontSize: fontSize, cols: cols, rows: rows,
                                                          descent: descent, xHeight: xHeight)
                    XCTAssertEqual(cached, fresh, "\(fontName) \(fontSize) @\(scale)x")
                }
            }
        }
    }

    @MainActor func testScrollTranslatesRowsAndMatchesFullEncoding() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let source = (0..<rows).map { $0 % 3 == 0 ? "row \($0) éⅢ∫" : "row \($0) ascii" }
        let shifted = Array(source.dropFirst(2)) + ["new é ten", "new ∫ eleven"]
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let initial = try snapshot(cells: source.enumerated().flatMap { line($0.offset, $0.element) },
                                       cursor: ["row": 4, "col": 2, "visible": true])
            let initialFrame = try XCTUnwrap(composer.compose(snapshot: initial, damage: nil, size: size, scale: scale,
                                                               fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                               appearance: .standard))
            try presenter.updateText(initialFrame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            let next = try snapshot(cells: shifted.enumerated().flatMap { line($0.offset, $0.element) },
                                    cursor: ["row": 3, "col": 1, "visible": true])
            let frame = try XCTUnwrap(composer.compose(snapshot: next, damage: [10, 11], size: size, scale: scale,
                                                       fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                       appearance: .standard, scroll: 2))
            XCTAssertEqual(composer.translatedRowCount, rows - 4, "scale \(scale)")
            XCTAssertEqual(composer.reencodedRowCount, 4, "two exposed and two cursor rows at scale \(scale)")
            XCTAssertEqual(composer.eligibilityScannedRows, rows, "scrolls use the full content reference scan")
            XCTAssertEqual(frame.dirtyRows, Array(0..<rows), "every moved row uploads")
            try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            let actual = try presenter.renderOffscreen(width: bitmapSize(scale).width, height: bitmapSize(scale).height)

            let reference = TextComposer()
            let full = try XCTUnwrap(reference.compose(snapshot: next, damage: nil, size: size, scale: scale,
                                                       fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                       appearance: .standard))
            try presenter.updateText(full, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            let expected = try presenter.renderOffscreen(width: bitmapSize(scale).width, height: bitmapSize(scale).height)
            XCTAssertEqual(actual, expected, "scale \(scale) matches a full atlas encode")
            let cpu = try GridRasterizer.make(snapshot: next, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            XCTAssertLessThanOrEqual(compare(cpu, actual).max, 2, "scale \(scale) matches the CPU rasterizer")
        }
    }

    func testScrollWithUnsafeBaselineRoundingFallsBackToFullEncoding() throws {
        let oddCell = CGSize(width: 8, height: 12), oddSize = CGSize(width: size.width, height: 157.0 / 3)
        let geometry = TextGeometry(cols: cols, rows: rows, cell: oddCell, scale: 3, size: oddSize,
                                    width: 1008, height: 157, descent: 7.0 / 3, xHeight: 8.0 / 3, phaseX: 0, phaseY: 0)
        let delta = oddCell.height * 3
        XCTAssertFalse((0..<rows - 1).allSatisfy {
            geometry.deviceOriginY(row: $0 + 1) - delta == geometry.deviceOriginY(row: $0)
        }, "this geometry must exercise the rounding guard")
        let composer = TextComposer()
        let source = (0..<rows).map { "row \($0)" }
        let initial = try snapshot(cells: source.enumerated().flatMap { line($0.offset, $0.element) })
        _ = try XCTUnwrap(composer.compose(snapshot: initial, damage: nil, size: oddSize, scale: 3,
                                           fontName: "Menlo", fontSize: 13, cell: oddCell, cjkFontName: "",
                                           appearance: .standard, prevalidated: geometry))
        let shifted = Array(source.dropFirst()) + ["last"]
        let next = try snapshot(cells: shifted.enumerated().flatMap { line($0.offset, $0.element) })
        let frame = try XCTUnwrap(composer.compose(snapshot: next, damage: [rows - 1], size: oddSize, scale: 3,
                                                   fontName: "Menlo", fontSize: 13, cell: oddCell, cjkFontName: "",
                                                   appearance: .standard, prevalidated: geometry, scroll: 1))
        XCTAssertEqual(composer.translatedRowCount, 0)
        XCTAssertEqual(composer.reencodedRowCount, rows)
        XCTAssertEqual(frame.dirtyRows, Array(0..<rows))
    }

    /// Exhaustion partway through a translated scroll discards that attempt and rebuilds every destination row
    /// into a fresh atlas before anything reaches the presenter.
    @MainActor func testScrollExhaustionRebuildsAllRowsBeforeHandoff() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        func stormCell(_ key: Int, row: Int, col: Int) -> [Any] {
            wire(row, col, text: String(UnicodeScalar(UInt8(65 + key % 8))),
                 Style(fg: [key % 251, (key / 251) % 251, (key / 63_001) % 251]))
        }
        for frame in 0..<8 {
            let cells = (0..<(rows * cols)).map { stormCell(frame * rows * cols + $0, row: $0 / cols, col: $0 % cols) }
            let storm = try XCTUnwrap(composer.compose(snapshot: try snapshot(cells: cells), damage: nil, size: size,
                                                       scale: 1, fontName: "Menlo", fontSize: 13, cell: cell,
                                                       cjkFontName: "", appearance: .standard))
            try presenter.updateText(storm, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 1))
        }
        XCTAssertEqual(composer.atlasEntries, 8 * rows * cols, "the storm leaves the atlas just under its cap")
        func coloured(_ row: Int) -> [[Any]] {
            (0..<cols).map { col in
                let key = row * cols + col
                return wire(row, col, text: String(UnicodeScalar(UInt8(65 + key % 8))),
                            Style(fg: [key % 251, (key / 251) % 251, 255]))
            }
        }
        let source = (0..<rows).map { "row \($0) ascii" }
        let cells = (0..<6).flatMap(coloured)
            + (6..<rows - 1).flatMap { line($0, source[$0 + 1]) }
            + coloured(rows - 1)
        let next = try snapshot(cells: cells)
        let frame = try XCTUnwrap(composer.compose(snapshot: next, damage: Set(0..<6), size: size, scale: 1,
                                                   fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                   appearance: .standard, scroll: 1))
        XCTAssertTrue(frame.resetAtlas, "the cap now triggers the same bounded rebuild as packing exhaustion")
        XCTAssertEqual(frame.dirtyRows, Array(0..<rows), "a partial translated attempt cannot certify row damage")
        XCTAssertEqual(composer.translatedRowCount, 0)
        XCTAssertEqual(composer.reencodedRowCount, rows)
        XCTAssertFalse(frame.uploads.isEmpty, "the fresh atlas is uploaded before the rebuilt rows")
        try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 1))
        let actual = try presenter.renderOffscreen(width: bitmapSize(1).width, height: bitmapSize(1).height)
        let reference = TextComposer()
        let full = try XCTUnwrap(reference.compose(snapshot: next, damage: nil, size: size, scale: 1,
                                                   fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                   appearance: .standard))
        try presenter.updateText(full, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 1))
        let expected = try presenter.renderOffscreen(width: bitmapSize(1).width, height: bitmapSize(1).height)
        XCTAssertEqual(actual, expected, "the rebuilt scroll frame matches a fresh full encode")
    }

    @MainActor func testDiscardedScrollRecoversWithoutApplyingItsShiftTwice() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer(), grid = GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2)
        let source = (0..<rows).map { "row \($0)" }
        let initial = try snapshot(cells: source.enumerated().flatMap { line($0.offset, $0.element) })
        try presenter.updateText(try XCTUnwrap(compose(initial, composer: composer, damage: nil)), grid: grid)
        let discardedLines = Array(source.dropFirst()) + ["discarded"]
        let discarded = try snapshot(cells: discardedLines.enumerated().flatMap { line($0.offset, $0.element) })
        _ = try XCTUnwrap(composer.compose(snapshot: discarded, damage: [rows - 1], size: size, scale: 2,
                                           fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                           appearance: .standard, deferPublication: true, scroll: 1))
        let finalLines = Array(source.dropFirst(2)) + ["penultimate", "final"]
        let final = try snapshot(cells: finalLines.enumerated().flatMap { line($0.offset, $0.element) })
        let recovered = try XCTUnwrap(composer.compose(snapshot: final, damage: [rows - 1], size: size, scale: 2,
                                                       fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                       appearance: .standard, scroll: 1))
        XCTAssertEqual(composer.translatedRowCount, 0, "recovery cannot translate the already-discarded shift")
        XCTAssertEqual(composer.reencodedRowCount, rows)
        XCTAssertEqual(composer.eligibilityScannedRows, rows, "discarded-frame recovery cannot reuse content certificates")
        XCTAssertEqual(recovered.dirtyRows, Array(0..<rows))
        XCTAssertFalse(recovered.uploads.isEmpty, "the discarded frame's new mask remains queued")
        try presenter.updateText(recovered, grid: grid)
        let actual = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        let full = try XCTUnwrap(compose(final, composer: TextComposer(), damage: nil))
        try presenter.updateText(full, grid: grid)
        let expected = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        XCTAssertEqual(actual, expected)
    }

    @MainActor func testScrollWhileFrameIsInFlightPublishesACompleteReplacement() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer(), grid = GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2)
        let source = (0..<rows).map { "row \($0)" }
        let initial = try snapshot(cells: source.enumerated().flatMap { line($0.offset, $0.element) })
        try presenter.updateText(try XCTUnwrap(compose(initial, composer: composer, damage: nil)), grid: grid)
        let held = try presenter.holdFrameInFlight()
        defer { held.release(); held.command.waitUntilCompleted() }
        let shifted = Array(source.dropFirst(2)) + ["new ten", "new eleven"]
        let next = try snapshot(cells: shifted.enumerated().flatMap { line($0.offset, $0.element) })
        let frame = try XCTUnwrap(composer.compose(snapshot: next, damage: [10, 11], size: size, scale: 2,
                                                   fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                   appearance: .standard, scroll: 2))
        try presenter.updateText(frame, grid: grid)
        XCTAssertEqual(frame.dirtyRows, Array(0..<rows))
        XCTAssertEqual(presenter.textFullUploads, 1)
        held.release(); held.command.waitUntilCompleted()
        waitUntilIdle(presenter)
        let actual = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        let full = try XCTUnwrap(compose(next, composer: TextComposer(), damage: nil))
        try presenter.updateText(full, grid: grid)
        let expected = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        XCTAssertEqual(actual, expected)
    }

    // MARK: Atlas retention and bounds

    /// Every geometric scalar shares one mask across style and colour, so long-running TUI colour changes cannot
    /// turn the fixed geometric repertoire into an atlas-growth workload.
    func testGeometricMasksAreBoundedAndColourIndependent() throws {
        let scalars = (0x2500...0x259F).map { UnicodeScalar($0)! } + (0x2801...0x28FF).map { UnicodeScalar($0)! }
        func cells(colourOffset: Int) -> [[Any]] {
            scalars.enumerated().map { index, scalar in
                let key = index + colourOffset
                return wire(index / cols, index % cols, text: String(scalar),
                            Style(fg: [key % 251, (key * 3) % 251, (key * 7) % 251],
                                  bold: index % 2 == 0, italic: index % 3 == 0))
            }
        }
        let composer = TextComposer()
        let first = try XCTUnwrap(compose(try snapshot(cells: cells(colourOffset: 0)), composer: composer, damage: nil))
        XCTAssertEqual(composer.atlasEntries, scalars.count)
        XCTAssertEqual(first.uploads.count, scalars.count)
        XCTAssertEqual(composer.atlasResets, 1, "the complete uniform repertoire fits without fragmentation")
        let resets = composer.atlasResets
        let second = try XCTUnwrap(compose(try snapshot(cells: cells(colourOffset: 37)), composer: composer,
                                           damage: Set(0..<rows)))
        XCTAssertTrue(second.uploads.isEmpty, "colour and font style do not create geometric masks")
        XCTAssertEqual(composer.atlasEntries, scalars.count)
        XCTAssertEqual(composer.atlasResets, resets)
    }

    /// A second frame with the same text reuses every mask: no atlas uploads and no new entries.
    @MainActor func testUnchangedGlyphsAreReusedFromTheAtlas() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        var cells: [[Any]] = []
        for row in 0..<rows { cells += line(row, "reuse \(row) abcdefghijkl") }
        let snapshot = try snapshot(cells: cells)
        let first = try XCTUnwrap(compose(snapshot, composer: composer, damage: nil))
        XCTAssertEqual(first.dirtyRows.count, rows, "the first frame is a full repaint")
        XCTAssertFalse(first.uploads.isEmpty, "the first frame rasterises masks")
        let entries = composer.atlasEntries
        XCTAssertGreaterThan(entries, 0)

        let second = try XCTUnwrap(compose(snapshot, composer: composer, damage: Set(0..<rows)))
        XCTAssertTrue(second.uploads.isEmpty, "cached glyphs upload no new coverage")
        XCTAssertEqual(composer.atlasEntries, entries, "no mask is rasterised twice")
        XCTAssertFalse(second.resetAtlas)
        // The upload path still runs, but the atlas texture is not recreated.
        _ = try render(snapshot, scale: 2, presenter: presenter, composer: composer, damage: Set(0..<rows))
        let generations = presenter.textAtlasGenerations
        _ = try render(snapshot, scale: 2, presenter: presenter, composer: composer, damage: Set(0..<rows))
        XCTAssertEqual(presenter.textAtlasGenerations, generations, "reused masks keep the atlas texture")
    }

    /// Only the rows the core damaged are re-encoded and re-uploaded.
    @MainActor func testOnlyDirtyRowsAreReEncodedAndUploaded() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        var cells: [[Any]] = []
        for row in 0..<rows { cells += line(row, "row \(row)") }
        let snapshot = try snapshot(cells: cells)
        _ = try render(snapshot, scale: 2, presenter: presenter, composer: composer)
        let before = presenter.textRowUploads
        let frame = try XCTUnwrap(compose(snapshot, composer: composer, damage: [3]))
        XCTAssertEqual(frame.dirtyRows, [3], "only row 3 was damaged")
        try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        XCTAssertEqual(presenter.textRowUploads - before, 1, "one uploaded instance row")
    }

    func testUnsupportedFrameAtDifferentLayoutPreservesAtlas() throws {
        let composer = TextComposer()
        let initial = try snapshot(cells: line(0, "layout"))
        _ = try XCTUnwrap(compose(initial, composer: composer, damage: nil))
        let resets = composer.atlasResets
        let unsupported = try snapshot(cells: [wire(0, 0, text: "👨‍👩‍👧", Style(wide: true))])
        XCTAssertNil(composer.compose(snapshot: unsupported, damage: [0], size: size, scale: 2,
                                      fontName: "Courier New", fontSize: 13, cell: cell,
                                      cjkFontName: "", appearance: .standard))
        let frame = try XCTUnwrap(compose(initial, composer: composer, damage: nil))
        XCTAssertFalse(frame.resetAtlas)
        XCTAssertEqual(composer.atlasResets, resets)
    }

    /// A new font, size or grid invalidates every UV, so the atlas is recreated and every row re-encoded.
    @MainActor func testLayoutChangeRecreatesTheAtlasAndReEncodesEveryRow() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        let snapshot = try snapshot(cells: line(0, "layout"))
        _ = try render(snapshot, scale: 2, presenter: presenter, composer: composer)
        let resets = composer.atlasResets
        let frame = try XCTUnwrap(composer.compose(snapshot: snapshot, damage: [2], size: size, scale: 2,
                                                   fontName: "Courier New", fontSize: 13, cell: cell,
                                                   cjkFontName: "", appearance: .standard))
        XCTAssertTrue(frame.resetAtlas)
        XCTAssertEqual(frame.dirtyRows.count, rows, "a new layout re-encodes every row")
        XCTAssertEqual(composer.eligibilityScannedRows, rows, "a new layout also invalidates content eligibility")
        XCTAssertGreaterThan(composer.atlasResets, resets)
        // The new font still matches the software reference.
        let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 2, fontName: "Courier New", fontSize: 13,
                                          cellSize: cell, composition: "")
        try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        let rendered = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        let result = compare(cpu, rendered)
        XCTAssertLessThanOrEqual(result.max, 2, "max channel difference \(result.max)")
    }

    /// The atlas never grows past its entry cap. Reaching the cap recreates the atlas and re-encodes the current
    /// frame instead of repeatedly attempting a full encode against an atlas with no free entries.
    @MainActor func testAtlasStaysBoundedUnderAColourStorm() throws {
        let composer = TextComposer()
        var completed = 0
        for frame in 0..<12 {
            var cells: [[Any]] = []
            for row in 0..<rows {
                for col in 0..<cols {
                    let key = frame * rows * cols + row * cols + col
                    let fg = [key % 251, (key / 251) % 251, (key / 63_001) % 251]
                    let glyph = String(UnicodeScalar(UInt8(65 + key % 8)))
                    cells.append(self.wire(row, col, text: glyph, Style(fg: fg)))
                }
            }
            let result = composer.compose(snapshot: try snapshot(cells: cells), damage: nil, size: size, scale: 1,
                                          fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                          appearance: .standard)
            if result != nil { completed += 1 }
            XCTAssertLessThanOrEqual(composer.atlasEntries, GlyphAtlas.maxEntries, "the atlas entry cap holds")
            // A recreate frame uploads every entry: none of a failed attempt's coverage may survive into the new
            // atlas, where it would overwrite a live entry at the same coordinates.
            if let result, result.resetAtlas { assertDisjoint(result.uploads, entries: composer.atlasEntries) }
        }
        XCTAssertEqual(completed, 12, "each current frame fits after old colours are discarded")
        XCTAssertGreaterThan(composer.atlasResets, 1, "the entry cap engages the bounded rebuild path")
        XCTAssertLessThanOrEqual(GlyphAtlas.maxEntries, 4096, "the entry cap is bounded")
        XCTAssertLessThanOrEqual(GlyphAtlas.textureSize, 2048, "one bounded atlas texture, never one per glyph")
    }

    /// A frame too large even for an empty atlas is refused after its bounded retry. The next smaller frame must
    /// still upload every cached mask that the refused attempt never handed to the presenter.
    func testRefusedFrameKeepsUnpublishedGlyphUploadsForRecovery() throws {
        let composer = TextComposer()
        let wideCols = 100, tallRows = 50
        let largeSize = CGSize(width: CGFloat(wideCols) * cell.width + 16, height: CGFloat(tallRows) * cell.height + 16)
        let cells = (0..<(wideCols * tallRows)).map { key in
            wire(key / wideCols, key % wideCols, text: "A", Style(fg: [key % 251, key / 251, 100]))
        }
        func make(_ cells: [[Any]], damage: Set<Int>?) throws -> TextFrame? {
            composer.compose(snapshot: try snapshot(cells: cells, cols: wideCols, rows: tallRows), damage: damage,
                             size: largeSize, scale: 1, fontName: "Menlo", fontSize: 5, cell: cell,
                             cjkFontName: "", appearance: .standard)
        }
        XCTAssertNil(try make(cells, damage: nil), "one frame cannot exceed the empty-atlas entry cap")
        let recovered = try XCTUnwrap(make([cells[0]], damage: [0]))
        XCTAssertFalse(recovered.uploads.isEmpty, "a cached but unpublished glyph still needs its pixels uploaded")
        XCTAssertEqual(recovered.dirtyRows.count, tallRows, "a refused frame cannot certify partial row damage")
    }

    func testRefusedFirstFrameKeepsItsAtlasResetUntilRecovery() throws {
        let composer = TextComposer()
        let wideCols = 100, tallRows = 50
        let largeSize = CGSize(width: CGFloat(wideCols) * cell.width + 16, height: CGFloat(tallRows) * cell.height + 16)
        let cells = (0..<(wideCols * tallRows)).map { key in
            wire(key / wideCols, key % wideCols, text: "A", Style(fg: [key % 251, key / 251, 100]))
        }
        func make(_ cells: [[Any]], damage: Set<Int>?) throws -> TextFrame? {
            composer.compose(snapshot: try snapshot(cells: cells, cols: wideCols, rows: tallRows), damage: damage,
                             size: largeSize, scale: 1, fontName: "Menlo", fontSize: 5, cell: cell,
                             cjkFontName: "", appearance: .standard)
        }
        XCTAssertNil(try make(cells, damage: nil))
        let recovered = try XCTUnwrap(make([cells[0]], damage: [0]))
        XCTAssertTrue(recovered.resetAtlas, "the presenter has never received this atlas layout")
        XCTAssertEqual(recovered.uploads.count, composer.atlasEntries)
        XCTAssertEqual(recovered.dirtyRows.count, tallRows)
    }

    /// A storm that keeps exhausting the atlas must stand down instead of re-rasterising the whole window
    /// through CoreText on every frame.
    func testPersistentAtlasExhaustionStandsDownToTheCpuPath() throws {
        let composer = TextComposer()
        var frames: [TextFrame?] = []
        // Large masks at 36 pt/3x repeatedly exhaust packing even though each current frame fits after a recreate.
        for frame in 0..<14 {
            var cells: [[Any]] = []
            for row in 0..<rows {
                for col in 0..<cols {
                    let key = frame * rows * cols + row * cols + col
                    let fg = [key % 251, (key / 251) % 251, (key / 63_001) % 251]
                    let glyph = String(UnicodeScalar(UInt8(65 + key % 8)))
                    cells.append(self.wire(row, col, text: glyph, Style(fg: fg)))
                }
            }
            frames.append(composer.compose(snapshot: try snapshot(cells: cells), damage: nil, size: size, scale: 3,
                                           fontName: "Menlo", fontSize: 36, cell: cell, cjkFontName: "",
                                           appearance: .standard))
        }
        XCTAssertTrue(composer.isSuspended, "repeated rebuilds stand down to the CPU path")
        XCTAssertNil(frames.last!, "a suspended composer refuses frames instead of rebuilding every time")
        XCTAssertGreaterThan(composer.atlasResets, 1, "the rebuild budget was spent before standing down")
        XCTAssertLessThanOrEqual(composer.atlasEntries, GlyphAtlas.maxEntries)
        let entries = composer.atlasEntries, resets = composer.atlasResets
        XCTAssertNil(composer.compose(snapshot: try snapshot(cells: line(0, "a")), damage: nil, size: size, scale: 3,
                                      fontName: "Menlo", fontSize: 36, cell: cell, cjkFontName: "", appearance: .standard),
                     "a suspended composer cannot resume in the same epoch")
        XCTAssertTrue(composer.isSuspended)
        XCTAssertEqual(composer.atlasEntries, entries)
        XCTAssertEqual(composer.atlasResets, resets)
        let otherSize = CGSize(width: size.width + 8, height: size.height)
        XCTAssertNil(composer.compose(snapshot: try snapshot(cells: [wire(0, 0, text: "👨‍👩‍👧")]), damage: nil, size: otherSize, scale: 3,
                                      fontName: "Menlo", fontSize: 36, cell: cell, cjkFontName: "",
                                      appearance: .standard))
        XCTAssertTrue(composer.isSuspended, "unsupported content at another layout cannot re-arm the atlas")
        XCTAssertEqual(composer.atlasResets, resets, "content refusal happens before a suspended layout reset")
        let colorEntries = composer.atlasEntries
        XCTAssertNil(composer.compose(snapshot: try snapshot(cells: line(0, "x⚠")), damage: nil, size: otherSize, scale: 3,
                                      fontName: "Apple Color Emoji", fontSize: 36, cell: cell, cjkFontName: "",
                                      appearance: .standard))
        XCTAssertTrue(composer.isSuspended, "a color-font layout cannot unsuspend the composer")
        XCTAssertEqual(composer.atlasEntries, colorEntries)
        XCTAssertEqual(composer.atlasResets, resets)
    }

    /// Standing down must not be permanent for the epoch: a repertoire that outgrew the atlas and then
    /// shrinks has to recover on its own, without a resize, font or theme change to re-arm it.
    func testSuspensionRecoversOnProbationAfterTheRetryInterval() throws {
        let composer = TextComposer()
        // Spend the rebuild budget the same way the exhaustion test does.
        for frame in 0..<14 {
            var cells: [[Any]] = []
            for row in 0..<rows {
                for col in 0..<cols {
                    let key = frame * rows * cols + row * cols + col
                    let fg = [key % 251, (key / 251) % 251, (key / 63_001) % 251]
                    cells.append(wire(row, col, text: String(UnicodeScalar(UInt8(65 + key % 8))), Style(fg: fg)))
                }
            }
            _ = composer.compose(snapshot: try snapshot(cells: cells), damage: nil, size: size, scale: 3,
                                 fontName: "Menlo", fontSize: 36, cell: cell, cjkFontName: "", appearance: .standard)
        }
        XCTAssertTrue(composer.isSuspended, "the rebuild budget stands the composer down")
        let small = try snapshot(cells: line(0, "ascii"))
        func composeSmall() -> TextFrame? {
            composer.compose(snapshot: small, damage: nil, size: size, scale: 3, fontName: "Menlo",
                             fontSize: 36, cell: cell, cjkFontName: "", appearance: .standard)
        }
        XCTAssertNil(composeSmall(), "a suspended composer must not retry on the very next frame")
        XCTAssertTrue(composer.isSuspended)
        // The frame the retry lands on depends on how many refusals the stand-down itself took, so only the
        // bound is asserted: within one probation interval the atlas path must come back on its own.
        for _ in 0..<TextComposer.suspensionRetryFrames { _ = composeSmall() }
        XCTAssertFalse(composer.isSuspended, "a shrunken repertoire recovers without a layout change")
        XCTAssertNotNil(composeSmall(), "the recovered composer draws from the atlas again")
    }

    @MainActor func testRejectedFontLayoutDoesNotCorruptTheActiveRenderer() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        let menlo = try snapshot(cells: line(0, "x"))
        _ = try render(menlo, scale: 2, presenter: presenter, composer: composer)
        let rejected = try snapshot(cells: [wire(0, 0, text: "é"), wire(0, 1, text: "👨‍👩‍👧")])
        XCTAssertNil(composer.compose(snapshot: rejected, damage: nil,
                                      size: size, scale: 2, fontName: "Courier New", fontSize: 13, cell: cell,
                                      cjkFontName: "", appearance: .standard),
                     "a rejected layout must fall back")
        let returnedSnapshot = try snapshot(cells: line(0, "yé"))
        let returned = try XCTUnwrap(compose(returnedSnapshot, composer: composer, damage: nil))
        try presenter.updateText(returned, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        let gpu = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        let cpu = try GridRasterizer.make(snapshot: returnedSnapshot, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                          cellSize: cell, composition: "")
        XCTAssertLessThanOrEqual(compare(cpu, gpu).max, 2, "the active Menlo renderer must survive a rejected font change")
    }

    func testColorFontRefusalDoesNotGrowAtlasOrUnsuspend() throws {
        let composer = TextComposer()
        let cells = line(0, "x⚠")
        XCTAssertNil(composer.compose(snapshot: try snapshot(cells: cells), damage: nil, size: size, scale: 2,
                                      fontName: "Apple Color Emoji", fontSize: 13, cell: cell, cjkFontName: "",
                                      appearance: .standard))
        XCTAssertEqual(composer.atlasEntries, 0)
        XCTAssertEqual(composer.atlasResets, 0)
        XCTAssertFalse(composer.isSuspended)
    }

    func testDecorationMasksAreColorIndependent() throws {
        let composer = TextComposer()
        let first = try XCTUnwrap(compose(try snapshot(cells: [wire(0, 0, text: "", Style(underline: true)),
                                                               wire(0, 1, text: "", Style(strike: true))]),
                                          composer: composer, damage: nil))
        XCTAssertFalse(first.uploads.isEmpty)
        let second = try XCTUnwrap(compose(try snapshot(cells: [wire(0, 0, text: "", Style(fg: [255, 0, 0], underline: true, underlineColor: [0, 255, 0])),
                                                                wire(0, 1, text: "", Style(fg: [0, 0, 255], strike: true))]),
                                           composer: composer, damage: [0]))
        XCTAssertTrue(second.uploads.isEmpty, "colour changes reuse the two colour-independent decoration masks")
    }

    @MainActor func testScrollTranslatesDecoratedRowsAndMatchesFullEncoding() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let style = Style(underline: true, strike: true)
        let source = (0..<rows).map { "éⅢ \($0)" }
        let shifted = Array(source.dropFirst(2)) + ["new é ten", "new ∫ eleven"]
        for scale: CGFloat in [1, 2, 3] {
            let composer = TextComposer()
            let initial = try snapshot(cells: source.enumerated().flatMap { line($0.offset, $0.element, style) },
                                       cursor: ["row": 4, "col": 2, "visible": true])
            try presenter.updateText(try XCTUnwrap(composer.compose(snapshot: initial, damage: nil, size: size, scale: scale,
                                                                    fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                                    appearance: .standard)),
                                     grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            let next = try snapshot(cells: shifted.enumerated().flatMap { line($0.offset, $0.element, style) },
                                    cursor: ["row": 3, "col": 1, "visible": true])
            let frame = try XCTUnwrap(composer.compose(snapshot: next, damage: [10, 11], size: size, scale: scale,
                                                       fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                       appearance: .standard, scroll: 2))
            XCTAssertEqual(composer.translatedRowCount, rows - 4, "scale \(scale)")
            XCTAssertEqual(composer.reencodedRowCount, 4, "two exposed and two cursor rows at scale \(scale)")
            try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            let actual = try presenter.renderOffscreen(width: bitmapSize(scale).width, height: bitmapSize(scale).height)
            let reference = TextComposer()
            let full = try XCTUnwrap(reference.compose(snapshot: next, damage: nil, size: size, scale: scale,
                                                       fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                       appearance: .standard))
            try presenter.updateText(full, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            XCTAssertEqual(actual, try presenter.renderOffscreen(width: bitmapSize(scale).width, height: bitmapSize(scale).height),
                           "scale \(scale) decorated scroll matches full encoding")
            let cpu = try GridRasterizer.make(snapshot: next, size: size, scale: scale, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
            XCTAssertLessThanOrEqual(compare(cpu, actual).max, 2, "scale \(scale) decorated scroll matches the CPU rasterizer")
        }
    }

    /// Leaving the window drops the atlas texture and the instance buffer.
    @MainActor func testLeavingTheWindowReleasesTextResources() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        // One colour cluster, so the release is proven to drop the 16 MiB page and not only the 4 MiB one.
        let snapshot = try snapshot(cells: line(0, "release\u{1F600}"))
        _ = try render(snapshot, scale: 2, presenter: presenter, composer: composer)
        XCTAssertTrue(presenter.textMode)
        XCTAssertTrue(presenter.hasTextResources)
        XCTAssertTrue(presenter.hasColourAtlas, "an emoji frame allocated the colour page")
        presenter.releaseTextures()
        composer.releaseFrames()
        XCTAssertFalse(presenter.textMode)
        XCTAssertFalse(presenter.hasTextResources)
        XCTAssertFalse(presenter.hasColourAtlas, "the colour page is released with the coverage atlas")
        // A fresh frame after the release rebuilds the buffer without throwing.
        let again = try XCTUnwrap(compose(snapshot, composer: composer, damage: nil))
        XCTAssertEqual(again.dirtyRows.count, rows)
        XCTAssertTrue(again.resetAtlas, "a released composer rebuilds rather than reusing stale UVs")
        XCTAssertTrue(again.usesColourPage, "the rebuilt frame draws its colour cluster again")
        try presenter.updateText(again, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        XCTAssertTrue(presenter.hasTextResources)
        XCTAssertTrue(presenter.hasColourAtlas, "the page is reallocated for the frame that needs it")
    }

    /// A live drag-resize is a layout change every frame, so every frame resets the atlas. Retired pages may
    /// only be reused once no frame can still sample them: while one is in flight a reset must allocate, and
    /// once it completes reuse must resume without a stale glyph surfacing.
    @MainActor func testAtlasPagesAreReusedOnlyOnceNoFrameCanSampleThem() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        let snapshot = try snapshot(cells: line(0, "abc\u{1F600}"))
        _ = try render(snapshot, scale: 2, presenter: presenter, composer: composer)
        let allocations = presenter.atlasPageAllocations
        XCTAssertEqual(allocations, 2, "one coverage page and one colour page")
        waitUntilIdle(presenter)

        let idle = try XCTUnwrap(composer.compose(snapshot: snapshot, damage: nil, size: size, scale: 3,
                                                  fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                  appearance: .standard))
        XCTAssertTrue(idle.resetAtlas, "a backing-scale change resets the atlas")
        try presenter.updateText(idle, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 3))
        XCTAssertEqual(presenter.atlasPageAllocations, allocations, "with the GPU idle both pages are reused")

        // A frame still on the GPU is sampling the retired pages, so this reset has to allocate new ones.
        let held = try presenter.holdFrameInFlight()
        let busy = try XCTUnwrap(composer.compose(snapshot: snapshot, damage: nil, size: size, scale: 2,
                                                  fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                  appearance: .standard))
        try presenter.updateText(busy, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        XCTAssertEqual(presenter.atlasPageAllocations, allocations + 2, "an in-flight frame's pages cannot be reused")
        held.release(); held.command.waitUntilCompleted()
        waitUntilIdle(presenter)
        // The busy-path frame allocated fresh pages rather than reusing them; check its pixels too, not only
        // its allocation count, so both paths are held to the same reference.
        let busyCPU = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                              cellSize: cell, composition: "")
        let busyGPU = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        let busyResult = compare(busyCPU, busyGPU)
        XCTAssertLessThanOrEqual(busyResult.max, 2, "freshly allocated busy-path pages match the CPU rasterizer")
        XCTAssertGreaterThan(busyResult.exact, 0.95)

        let after = try XCTUnwrap(composer.compose(snapshot: snapshot, damage: nil, size: size, scale: 3,
                                                   fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                   appearance: .standard))
        try presenter.updateText(after, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 3))
        XCTAssertEqual(presenter.atlasPageAllocations, allocations + 2, "completed pages come back into use")
        let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 3, fontName: "Menlo", fontSize: 13,
                                          cellSize: cell, composition: "")
        let gpu = try presenter.renderOffscreen(width: bitmapSize(3).width, height: bitmapSize(3).height)
        let result = compare(cpu, gpu)
        XCTAssertLessThanOrEqual(result.max, 2, "a reused page holds no stale glyphs")
        XCTAssertGreaterThan(result.exact, 0.95, "a reused page matches the CPU rasterizer")

        // Leaving the window frees the pool rather than parking 20 MiB for a pane that may never return.
        presenter.releaseTextures()
        composer.releaseFrames()
        XCTAssertFalse(presenter.hasColourAtlas)
        let back = try XCTUnwrap(compose(snapshot, composer: composer, damage: nil))
        try presenter.updateText(back, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        XCTAssertEqual(presenter.atlasPageAllocations, allocations + 4, "release empties the pool")
    }

    /// Two frames in flight is the normal drag-resize pipeline, and with emoji every reset parks two pages,
    /// so the pool reaches its cap. Taking both pages before retiring either is what stops the cap evicting
    /// the page that has just become reusable. Without that ordering reuse collapses to zero here.
    @MainActor func testAtlasReuseSurvivesTwoFramesInFlightAndPrunesWhenIdle() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        let snapshot = try snapshot(cells: line(0, "abc\u{1F600}"))
        _ = try render(snapshot, scale: 2, presenter: presenter, composer: composer)
        waitUntilIdle(presenter)
        var held: [(command: MTLCommandBuffer, release: () -> Void)] = []
        defer { held.forEach { $0.release(); $0.command.waitUntilCompleted() } }
        for scale: CGFloat in [3, 2, 3] {
            let frame = try XCTUnwrap(composer.compose(snapshot: snapshot, damage: nil, size: size, scale: scale,
                                                       fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                       appearance: .standard))
            XCTAssertTrue(frame.resetAtlas, "a scale change resets the atlas")
            try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
            held.append(try presenter.holdFrameInFlight())
        }
        let allocations = presenter.atlasPageAllocations
        XCTAssertGreaterThan(presenter.retiredAtlasCount, 0, "the busy resets parked pages")
        // Let the oldest held frame finish: its pages are now reusable, and the pool is at its cap, so this
        // reset is exactly the case where retiring first would evict them before they could be taken.
        held.removeFirst().release()
        let reused = try XCTUnwrap(composer.compose(snapshot: snapshot, damage: nil, size: size, scale: 2,
                                                    fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                    appearance: .standard))
        try presenter.updateText(reused, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        XCTAssertEqual(presenter.atlasPageAllocations, allocations, "completed pages are reused, not evicted by the cap")

        held.forEach { $0.release() }
        held.removeAll()
        waitUntilIdle(presenter)
        // Steady-state frames must not keep the burst's pages alive forever.
        let steady = try XCTUnwrap(compose(snapshot, composer: composer, damage: []))
        try presenter.updateText(steady, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        XCTAssertEqual(presenter.retiredAtlasCount, 0, "completed pages are pruned once the burst is over")
    }

    /// No two masks may claim the same atlas region in one frame.
    private func assertDisjoint(_ uploads: [GlyphAtlas.Upload], entries: Int) {
        XCTAssertEqual(uploads.count, entries, "every recreated entry is uploaded exactly once")
        for first in uploads.indices {
            for second in uploads.indices where second > first {
                let a = uploads[first], b = uploads[second]
                let overlaps = a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
                XCTAssertFalse(overlaps, "atlas upload regions overlap")
            }
        }
    }

    /// No two colour tiles may claim the same region of the colour page in one frame.
    private func assertColourDisjoint(_ uploads: [GlyphAtlas.ColourUpload], entries: Int) {
        XCTAssertEqual(uploads.count, entries, "every recreated colour tile is uploaded exactly once")
        for first in uploads.indices {
            for second in uploads.indices where second > first {
                let a = uploads[first], b = uploads[second]
                let overlaps = a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
                XCTAssertFalse(overlaps, "colour tile regions overlap")
            }
        }
    }

    /// The instance layout the shader indexes must stay 48 bytes: three float4s.
    func testInstanceLayoutMatchesTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<TextInstance>.stride, 48)
        XCTAssertEqual(MemoryLayout<TextInstance>.size, 48)
        XCTAssertEqual(MemoryLayout<TextInstance>.alignment, 4)
    }

    // MARK: Helpers

    /// Two adjacent cells decoded the way the core sends them, for exercising `GlyphClusters.merge`.
    private func cellPair(_ first: String, _ second: String) throws -> [Cell] {
        try snapshot(cells: [wire(0, 0, text: first), wire(0, 1, text: second)]).cells
    }

    private func compose(_ snapshot: Snapshot, composer: TextComposer, damage: Set<Int>?) -> TextFrame? {
        composer.compose(snapshot: snapshot, damage: damage, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                         cell: cell, cjkFontName: "", appearance: .standard)
    }

    @MainActor private func render(_ snapshot: Snapshot, scale: CGFloat, presenter: MetalPresenter, composer: TextComposer,
                                   damage: Set<Int>? = nil, appearance: RenderAppearance = .standard) throws -> (TextFrame, Data) {
        presenter.clearColor = MetalPresenter.clearColor(for: appearance.backgroundColor)
        let frame = try XCTUnwrap(composer.compose(snapshot: snapshot, damage: damage, size: size, scale: scale,
                                                   fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                   appearance: appearance), "the composer covers this frame")
        try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: scale))
        let (width, height) = bitmapSize(scale)
        return (frame, try presenter.renderOffscreen(width: width, height: height))
    }

    /// Waits for the queue to drain without blocking on a completion handler that needs the main queue.
    @MainActor private func waitUntilIdle(_ presenter: MetalPresenter, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while presenter.pendingFrameCount > 0 && Date() < deadline { usleep(2_000) }
        XCTAssertEqual(presenter.pendingFrameCount, 0, "the GPU drained within the deadline")
    }

    /// Device pixels whose colour differs, with the rectangle that bounds them.
    private func differences(_ cpu: CGContext, _ gpu: Data) -> (count: Int, box: CGRect?) {
        let left = cpu.data!.assumingMemoryBound(to: UInt8.self)
        let right = gpu.withUnsafeBytes { $0.bindMemory(to: UInt8.self) }
        var count = 0
        var box: CGRect?
        for y in 0..<cpu.height {
            for x in 0..<cpu.width {
                let offset = y * cpu.bytesPerRow + x * 4
                var delta = 0
                for channel in 0..<3 { delta = max(delta, abs(Int(left[offset + channel]) - Int(right[offset + channel]))) }
                guard delta != 0 else { continue }
                count += 1
                let point = CGRect(x: x, y: y, width: 1, height: 1)
                box = box.map { $0.union(point) } ?? point
            }
        }
        return (count, box)
    }

    private func bytes(_ context: CGContext) -> Data { Data(bytes: context.data!, count: context.bytesPerRow * context.height) }

    /// Device pixels that differ from the top-left corner: a frame whose fills painted nothing would return zero.
    private func paintedPixels(_ context: CGContext) -> Int {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let corner = (0, 0)
        let base = (corner.1 * context.bytesPerRow + corner.0 * 4)
        var count = 0
        for y in 0..<context.height {
            for x in 0..<context.width {
                let offset = y * context.bytesPerRow + x * 4
                if data[offset] != data[base] || data[offset + 1] != data[base + 1] || data[offset + 2] != data[base + 2] { count += 1 }
            }
        }
        return count
    }

    /// Per-pixel BGRA comparison of the CPU bitmap and the GPU readback: worst channel difference and the
    /// fraction of pixels that are identical.
    private func compare(_ cpu: CGContext, _ gpu: Data) -> (max: Int, exact: Double) {
        let left = cpu.data!.assumingMemoryBound(to: UInt8.self)
        let right = gpu.withUnsafeBytes { $0.bindMemory(to: UInt8.self) }
        var worst = 0, identical = 0, total = 0
        for y in 0..<cpu.height {
            for x in 0..<cpu.width {
                let offset = y * cpu.bytesPerRow + x * 4
                var delta = 0
                for channel in 0..<3 { delta = max(delta, abs(Int(left[offset + channel]) - Int(right[offset + channel]))) }
                worst = max(worst, delta)
                if delta == 0 { identical += 1 }
                total += 1
            }
        }
        return (worst, Double(identical) / Double(total))
    }

    private func placement(id: UInt32, gen: UInt64 = 1, row: Int = 0, col: Int = 4, cols: Int = 3, rows: Int = 1, z: Int = 0,
                           w: Int = 60, h: Int = 40) -> ImagePlacement {
        let value: [String: Any] = ["id": id, "gen": gen, "w": w, "h": h, "row": row, "col": col, "cols": cols, "rows": rows, "z": z]
        return try! JSONDecoder().decode(ImagePlacement.self, from: JSONSerialization.data(withJSONObject: value))
    }

    /// Cell attributes as the core sends them; a cell holds one grapheme, so `line` expands a string across columns.
    private struct Style {
        var fg: [Int] = [218, 226, 239]
        var bg: [Int] = [8, 10, 13]
        var selected = false, underline = false, strike = false, bold = false, italic = false
        var underlineStyle: UInt8? = nil, underlineColor: [Int]? = nil
        var search = false, activeSearch = false, wide = false
    }
    /// One cell in the wire form: `[row, col, text, fg, bg, attrs]`. Attrs bits are 1 bold, 2 italic,
    /// 4 underline, 8 selected, 16 wide, 32 strike, 64 search, 128 active search.
    private func wire(_ row: Int, _ col: Int, text: String = "", _ style: Style = Style()) -> [Any] {
        let attrs = (style.bold ? 1 : 0) | (style.italic ? 2 : 0)
            | (style.underline ? 4 | Int(style.underlineStyle ?? 1) << 8 : 0) | (style.selected ? 8 : 0)
            | (style.wide ? 16 : 0) | (style.strike ? 32 : 0) | (style.search ? 64 : 0) | (style.activeSearch ? 128 : 0)
        var result: [Any] = [row, col, text, style.fg[0] << 16 | style.fg[1] << 8 | style.fg[2],
                             style.bg[0] << 16 | style.bg[1] << 8 | style.bg[2], attrs]
        if let color = style.underlineColor { result.append(color[0] << 16 | color[1] << 8 | color[2]) }
        return result
    }
    /// A string laid out one grapheme per column, as a real snapshot carries it.
    private func line(_ row: Int, _ text: String, col: Int = 0, _ style: Style = Style()) -> [[Any]] {
        text.enumerated().map { offset, character in wire(row, col + offset, text: String(character), style) }
    }

    /// A wide cell in the form the core actually emits it: a two-column lead plus a blank spacer that
    /// inherits the lead's presentation. `line` would instead mark both halves as carrying text, which
    /// the core never produces and which would hide spacer-specific bugs.
    private func wideCell(_ row: Int, _ col: Int, text: String, _ style: Style = Style()) -> [[Any]] {
        var lead = style; lead.wide = true
        return [wire(row, col, text: text, lead), wire(row, col + 1, text: "", style)]
    }

    /// One wide cell per character, laid out two columns apart.
    private func wideLine(_ row: Int, _ text: String, col: Int = 0, _ style: Style = Style()) -> [[Any]] {
        text.enumerated().flatMap { offset, character in wideCell(row, col + offset * 2, text: String(character), style) }
    }

    private func snapshot(cells: [[Any]] = [], images: [ImagePlacement] = [], cols: Int? = nil, rows: Int? = nil,
                          cursor: [String: Any] = ["row": 4, "col": 2, "visible": false]) throws -> Snapshot {
        let cols = cols ?? self.cols, rows = rows ?? self.rows
        let object: [String: Any] = ["changed": true, "revision": 1, "cols": cols, "rows": rows, "title": "", "cells": cells,
            "lines": Array(repeating: String(repeating: " ", count: cols), count: rows), "images": images.map { placement in
                ["id": placement.id, "gen": placement.gen, "w": placement.w, "h": placement.h, "row": placement.row,
                 "col": placement.col, "cols": placement.cols, "rows": placement.rows, "z": placement.z]
            }, "cursor": cursor, "bracketed_paste": false, "app_cursor": false, "mouse_mode": false,
            "mouse_sgr": false, "mouse_drag": false, "mouse_motion": false, "focus_reporting": false, "alternate": false,
            "offset": 0, "history": 0, "clipboard": [] as [String], "exited": false]
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
