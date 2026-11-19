import XCTest
import CoreGraphics
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

    /// The composer's per-row bound is the presenter's buffer stride: a worst-case row (a fill and a glyph in
    /// every column, plus all four cursor bands) must fit without truncation.
    @MainActor func testAWorstCaseRowFitsTheInstanceCapacity() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let capacity = MetalPresenter.textRowCapacity(cols: cols)
        var cells: [[Any]] = []
        for col in 0..<cols {
            cells.append(wire(0, col, text: "X", Style(bg: [30, 30, 30], selected: col % 2 == 0)))
        }
        let snapshot = try snapshot(cells: cells, cursor: ["row": 0, "col": cols - 1, "visible": true])
        let frame = try XCTUnwrap(compose(snapshot, composer: TextComposer(), damage: nil))
        XCTAssertEqual(frame.content[0].count, capacity, "the worst-case row uses exactly the stated capacity")
        try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        // One instance beyond the capacity is a programming error, not something to truncate silently.
        let overflowing = TextFrame(rows: 1, dirtyRows: [0],
                                    content: [Array(repeating: .zero, count: capacity + 1)],
                                    uploads: [], resetAtlas: true)
        XCTAssertThrowsError(try presenter.updateText(overflowing, grid: GridGeometry(cols: 1, rows: 1, cell: cell, scale: 2)),
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
        let plan = RenderReuse.plan(damage: [1], scroll: 0, layered: false, textEligible: true,
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
            RenderReuse.plan(damage: damage, scroll: scroll, layered: layered, textEligible: eligible,
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
        XCTAssertEqual(try fallback(line(0, "漢字")), .nonASCII, "CJK keeps the software path")
        XCTAssertEqual(try fallback([wire(0, 0, text: "e\u{0301}")]), .nonASCII, "combining text keeps the software path")
        XCTAssertEqual(try fallback([wire(0, 0, text: "👨‍👩‍👧")]), .nonASCII, "emoji keeps the software path")
        XCTAssertEqual(try fallback([wire(0, 0, text: "│")]), .boxGlyph, "box drawing is geometric, not a font glyph")
        XCTAssertEqual(try fallback(line(0, "und", Style(underline: true))), .decoratedCell, "underlines keep the CPU path")
        XCTAssertEqual(try fallback(line(0, "gone", Style(strike: true))), .decoratedCell, "strikethrough keeps the CPU path")
        XCTAssertEqual(try fallback([wire(0, 0, text: "中", Style(wide: true))]), .wideCell, "wide cells keep the CPU path")
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
        XCTAssertNil(composer.compose(snapshot: try snapshot(cells: line(0, "漢字")), damage: nil, size: size,
                                      scale: 2, fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                      appearance: .standard), "a CJK frame must not be silently drawn as blanks")
    }

    @MainActor func testScrollTranslatesRowsAndMatchesFullEncoding() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let source = (0..<rows).map { "row \($0) ascii" }
        let shifted = Array(source.dropFirst(2)) + ["new ten", "new eleven"]
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
                                    width: 1008, height: 157, descent: 7.0 / 3, phaseX: 0, phaseY: 0)
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

    /// A scroll frame can be refused partway through its re-encode, after translating rows and replacing
    /// some of them. The next frame must re-encode every row from the snapshot, not trust the retained rows.
    @MainActor func testScrollRefusedMidBuildRecoversWithAFullReencode() throws {
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
        // Six damaged rows plus the exposed bottom row need more fresh masks than the remaining headroom;
        // the first rows fit, so the cap is hit partway through the re-encode, not before it starts.
        func coloured(_ row: Int) -> [[Any]] {
            (0..<cols).map { col in
                let key = row * cols + col
                return wire(row, col, text: String(UnicodeScalar(UInt8(65 + key % 8))),
                            Style(fg: [key % 251, (key / 251) % 251, 255]))
            }
        }
        let source = (0..<rows).map { "row \($0) ascii" }
        let refusedCells = (0..<6).flatMap(coloured)
            + (6..<rows - 1).flatMap { line($0, source[$0 + 1]) }
            + coloured(rows - 1)
        let refused = try snapshot(cells: refusedCells)
        XCTAssertNil(composer.compose(snapshot: refused, damage: Set(0..<6), size: size, scale: 1,
                                      fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                      appearance: .standard, scroll: 1), "the over-capacity scroll frame is refused")
        // Recovery re-encodes a scroll whose every mask the storm already cached: no row may keep the
        // refused attempt's translated or half-replaced instances.
        let recoveryCells = (0..<(rows - 1)).flatMap { row in
            (0..<cols).map { stormCell(7 * rows * cols + (row + 1) * cols + $0, row: row, col: $0) }
        } + (0..<cols).map { stormCell(6 * rows * cols + $0, row: rows - 1, col: $0) }
        let next = try snapshot(cells: recoveryCells)
        let frame = try XCTUnwrap(composer.compose(snapshot: next, damage: [rows - 1], size: size, scale: 1,
                                                   fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                   appearance: .standard, scroll: 1))
        XCTAssertFalse(frame.resetAtlas, "cached masks recover without an atlas reset")
        XCTAssertEqual(frame.dirtyRows, Array(0..<rows), "recovery cannot certify partial row damage")
        XCTAssertEqual(composer.translatedRowCount, 0)
        XCTAssertEqual(composer.reencodedRowCount, rows)
        XCTAssertFalse(frame.uploads.isEmpty, "the refused attempt's unpublished masks still reach the GPU")
        try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 1))
        let actual = try presenter.renderOffscreen(width: bitmapSize(1).width, height: bitmapSize(1).height)
        let reference = TextComposer()
        let full = try XCTUnwrap(reference.compose(snapshot: next, damage: nil, size: size, scale: 1,
                                                   fontName: "Menlo", fontSize: 13, cell: cell, cjkFontName: "",
                                                   appearance: .standard))
        try presenter.updateText(full, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 1))
        let expected = try presenter.renderOffscreen(width: bitmapSize(1).width, height: bitmapSize(1).height)
        XCTAssertEqual(actual, expected, "the recovered scroll frame matches a fresh full encode")
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
        XCTAssertGreaterThan(composer.atlasResets, resets)
        // The new font still matches the software reference.
        let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 2, fontName: "Courier New", fontSize: 13,
                                          cellSize: cell, composition: "")
        try presenter.updateText(frame, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        let rendered = try presenter.renderOffscreen(width: bitmapSize(2).width, height: bitmapSize(2).height)
        let result = compare(cpu, rendered)
        XCTAssertLessThanOrEqual(result.max, 2, "max channel difference \(result.max)")
    }

    /// The atlas never grows past its entry cap: a frame that needs more distinct masks than the cap is refused
    /// so the CPU rasterizer draws it, rather than being drawn with missing or overwritten glyphs.
    @MainActor func testAtlasStaysBoundedUnderAColourStorm() throws {
        let composer = TextComposer()
        var refused = 0
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
            if result == nil { refused += 1 }
            XCTAssertLessThanOrEqual(composer.atlasEntries, GlyphAtlas.maxEntries, "the atlas entry cap holds")
            // A recreate frame uploads every entry: none of a failed attempt's coverage may survive into the new
            // atlas, where it would overwrite a live entry at the same coordinates.
            if let result, result.resetAtlas { assertDisjoint(result.uploads, entries: composer.atlasEntries) }
        }
        XCTAssertGreaterThan(refused, 0, "an over-capacity frame is refused instead of drawn with missing glyphs")
        XCTAssertLessThanOrEqual(GlyphAtlas.maxEntries, 4096, "the entry cap is bounded")
        XCTAssertLessThanOrEqual(GlyphAtlas.textureSize, 2048, "one bounded atlas texture, never one per glyph")
    }

    /// A refused build can add masks without publishing them to the GPU.
    func testRefusedFrameKeepsUnpublishedGlyphUploadsForRecovery() throws {
        let composer = TextComposer()
        for frame in 0..<12 {
            let cells = (0..<(rows * cols)).map { index -> [Any] in
                let key = frame * rows * cols + index
                return wire(index / cols, index % cols, text: "A", Style(fg: [key % 251, key / 251, 100]))
            }
            func make(_ snapshot: Snapshot, damage: Set<Int>?) -> TextFrame? {
                composer.compose(snapshot: snapshot, damage: damage, size: size, scale: 1,
                                 fontName: "Menlo", fontSize: 5, cell: cell, cjkFontName: "", appearance: .standard)
            }
            if make(try snapshot(cells: cells), damage: nil) != nil { continue }
            // This frame inserted some masks before reaching the entry cap. A smaller frame can reuse
            // its first glyph, but that mask has never been delivered to the presenter.
            let recovered = try XCTUnwrap(make(try snapshot(cells: [cells[0]]), damage: [0]))
            XCTAssertFalse(recovered.uploads.isEmpty, "a cached but unpublished glyph still needs its pixels uploaded")
            XCTAssertEqual(recovered.dirtyRows.count, rows, "a refused frame cannot certify partial row damage")
            return
        }
        XCTFail("the colour workload must reach the entry cap")
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
        // Large masks at 36 pt/3x fill the packing well below the entry cap, so the recreate path is exercised
        // rather than the cheaper "refuse this frame" path.
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
    }

    /// Leaving the window drops the atlas texture and the instance buffer.
    @MainActor func testLeavingTheWindowReleasesTextResources() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let composer = TextComposer()
        let snapshot = try snapshot(cells: line(0, "release"))
        _ = try render(snapshot, scale: 2, presenter: presenter, composer: composer)
        XCTAssertTrue(presenter.textMode)
        XCTAssertTrue(presenter.hasTextResources)
        presenter.releaseTextures()
        composer.releaseFrames()
        XCTAssertFalse(presenter.textMode)
        XCTAssertFalse(presenter.hasTextResources)
        // A fresh frame after the release rebuilds the buffer without throwing.
        let again = try XCTUnwrap(compose(snapshot, composer: composer, damage: nil))
        XCTAssertEqual(again.dirtyRows.count, rows)
        try presenter.updateText(again, grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2))
        XCTAssertTrue(presenter.hasTextResources)
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

    /// The instance layout the shader indexes must stay 48 bytes: three float4s.
    func testInstanceLayoutMatchesTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<TextInstance>.stride, 48)
        XCTAssertEqual(MemoryLayout<TextInstance>.size, 48)
        XCTAssertEqual(MemoryLayout<TextInstance>.alignment, 4)
    }

    // MARK: Helpers

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
        var search = false, activeSearch = false, wide = false
    }
    /// One cell in the wire form: `[row, col, text, fg, bg, attrs]`. Attrs bits are 1 bold, 2 italic,
    /// 4 underline, 8 selected, 16 wide, 32 strike, 64 search, 128 active search.
    private func wire(_ row: Int, _ col: Int, text: String = "", _ style: Style = Style()) -> [Any] {
        let attrs = (style.bold ? 1 : 0) | (style.italic ? 2 : 0) | (style.underline ? 4 | 1 << 8 : 0) | (style.selected ? 8 : 0)
            | (style.wide ? 16 : 0) | (style.strike ? 32 : 0) | (style.search ? 64 : 0) | (style.activeSearch ? 128 : 0)
        return [row, col, text, style.fg[0] << 16 | style.fg[1] << 8 | style.fg[2],
                style.bg[0] << 16 | style.bg[1] << 8 | style.bg[2], attrs]
    }
    /// A string laid out one grapheme per column, as a real snapshot carries it.
    private func line(_ row: Int, _ text: String, col: Int = 0, _ style: Style = Style()) -> [[Any]] {
        text.enumerated().map { offset, character in wire(row, col + offset, text: String(character), style) }
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
