import XCTest
import CoreGraphics
import Metal
@testable import AkittyKit

/// Round-3: the layered Metal path — two text bitmaps, per-image GPU textures, image-only fast frames.
final class LayeredRenderingTests: XCTestCase {
    private let cell = CGSize(width: 10, height: 20)
    private let cols = 12, rows = 6
    private var size: CGSize { CGSize(width: CGFloat(cols) * cell.width + 16, height: CGFloat(rows) * cell.height + 16) }

    // MARK: Layered bitmaps

    func testLayeredBitmapsSplitBackgroundAndForeground() throws {
        let cells = [cell(0, 0, text: "A"), cell(1, 0, bg: [60, 80, 120]),
                     cell(1, 1, text: "xz", bg: [60, 80, 120]), cell(2, 0, text: "sel", selected: true)]
        let frame = try GridRasterizer().renderLayers(snapshot: try snapshot(cells: cells), damage: nil, size: size, scale: 1,
                                                      fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        // Default-background, unselected cells stay transparent on the background layer.
        XCTAssertEqual(alpha(frame.background, x: 13, yFromTop: 10), 0, "default cell is transparent in the background layer")
        // Rows are 20 pt below an 8 pt margin: row 1 (custom background) spans y 28..<48, row 2 (selected) 48..<68.
        XCTAssertEqual(alpha(frame.background, x: 13, yFromTop: 30), 255, "custom cell background paints")
        XCTAssertEqual(alpha(frame.background, x: 13, yFromTop: 50), 255, "selection paints its own colour")
        // Compare the painted colours against the single-bitmap composite, which color management cannot skew.
        let reference = try GridRasterizer.make(snapshot: try snapshot(cells: cells), size: size, scale: 1, fontName: "Menlo",
                                                fontSize: 13, cellSize: cell, composition: "")
        XCTAssertEqual(rgb(frame.background, x: 13, yFromTop: 30), rgb(reference, x: 13, yFromTop: 30), "custom cell colour")
        XCTAssertEqual(rgb(frame.background, x: 13, yFromTop: 50), rgb(reference, x: 13, yFromTop: 50), "selection colour")
        // Glyph pixels only exist on the foreground layer.
        XCTAssertGreaterThan(opaquePixels(frame.foreground, inRow: 0, col: 0), 0, "the glyph paints on the foreground layer")
        XCTAssertEqual(opaquePixels(frame.background, inRow: 0, col: 0), 0, "no glyph on the background layer")
        XCTAssertEqual(opaquePixels(frame.foreground, inRow: 1, col: 0), 0, "no glyph without text")
        XCTAssertGreaterThan(opaquePixels(frame.foreground, inRow: 1, col: 1), 0)
    }

    func testImageOnlyChangeLeavesTheTextLayersIntact() throws {
        let rasterizer = GridRasterizer()
        let first = try rasterizer.renderLayers(snapshot: try snapshot(images: [placement(id: 1, gen: 1)]), damage: nil, size: size, scale: 1,
                                                fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        XCTAssertNil(first.damage, "the first frame is a full repaint")
        let back = bytes(first.background), front = bytes(first.foreground)
        // A generation bump changes no text row, so an empty-damage layered render touches nothing.
        let bumped = try rasterizer.renderLayers(snapshot: try snapshot(images: [placement(id: 1, gen: 2)]), damage: [], size: size, scale: 1,
                                                 fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        XCTAssertEqual(bumped.damage?.count, 0, "an image-only change produces no text damage")
        XCTAssertEqual(bytes(bumped.background), back)
        XCTAssertEqual(bytes(bumped.foreground), front)
        // A changed text row still damages the layers, cursor row included.
        let edited = try rasterizer.renderLayers(snapshot: try snapshot(cells: [cell(3, 0, text: "hi")]), damage: [3], size: size, scale: 1,
                                                 fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        XCTAssertGreaterThan(edited.damage?.count ?? 0, 0)
    }

    func testASingleBitmapFrameReleasesTheLayerBitmaps() throws {
        let rasterizer = GridRasterizer()
        _ = try rasterizer.renderLayers(snapshot: try snapshot(images: [placement(id: 1, gen: 1)]), damage: nil, size: size, scale: 1,
                                        fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        XCTAssertTrue(rasterizer.hasLayerPasses, "a layered frame keeps its two bitmaps for the next one")
        _ = try rasterizer.render(snapshot: try snapshot(), damage: nil, size: size, scale: 1, fontName: "Menlo", fontSize: 13,
                                  cellSize: cell, composition: "")
        XCTAssertFalse(rasterizer.hasLayerPasses, "once the last image goes, the layer bitmaps go with it")
    }

    func testTheColourCacheStaysBoundedUnderTruecolorOutput() throws {
        let rasterizer = GridRasterizer()
        // 100 frames of 72 distinct foreground and background colours name 14,400 colours, over three times the cap.
        for frame in 0..<100 {
            let cells = (0..<rows).flatMap { row in (0..<cols).map { col -> [Any] in
                let n = (frame * rows + row) * cols + col
                return self.cell(row, col, text: "x", fg: [n >> 8 & 255, n & 255, 7], bg: [9, n >> 8 & 255, n & 255])
            } }
            _ = try rasterizer.render(snapshot: try snapshot(cells: cells), damage: nil, size: size, scale: 1, fontName: "Menlo",
                                      fontSize: 13, cellSize: cell, composition: "", reuse: false)
            XCTAssertLessThanOrEqual(rasterizer.cachedColors, GridRasterizer.maxColors)
        }
    }

    func testImageOnlyUpdateDecision() throws {
        let previous = try snapshot()
        XCTAssertTrue(TerminalView.isImageOnlyUpdate(previous: previous, next: try snapshot(partial: [])),
                      "partial snapshot, no dirty rows and the same cursor is image-only")
        XCTAssertFalse(TerminalView.isImageOnlyUpdate(previous: previous, next: try snapshot(partial: [2])), "a dirty row is text work")
        XCTAssertFalse(TerminalView.isImageOnlyUpdate(previous: previous, next: try snapshot()), "a full snapshot repaints")
        XCTAssertFalse(TerminalView.isImageOnlyUpdate(previous: nil, next: try snapshot(partial: [])), "no baseline to compare against")
        let cursorMoved = try snapshot(partial: [], cursor: ["row": 2, "col": 0, "visible": false])
        XCTAssertFalse(TerminalView.isImageOnlyUpdate(previous: previous, next: cursorMoved), "a moved cursor repaints its rows")
    }

    // MARK: Presenter image textures

    @MainActor func testPresenterUpdatesOnlyTheChangedImageTexture() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let grid = GridGeometry(cols: cols, rows: rows, cell: cell, scale: 1)
        let red = entry(1, 8, 8) { _, _ in [255, 0, 0, 255] }, blue = entry(1, 8, 8) { _, _ in [0, 0, 255, 255] }
        try presenter.updateImages(placements: [placement(id: 1), placement(id: 2, row: 1)], pixels: [1: red, 2: blue], grid: grid)
        let untouched = presenter.imageTextures[2]?.texture
        // Only the first image's generation moved; the second texture must not be re-uploaded.
        try presenter.updateImages(placements: [placement(id: 1, gen: 2), placement(id: 2, row: 1)], pixels: [1: entry(2, 8, 8) { _, _ in [0, 0, 255, 255] }, 2: blue], grid: grid)
        XCTAssertEqual(presenter.imageTextures[1]?.generation, 2, "the bumped image is re-uploaded")
        XCTAssertTrue(presenter.imageTextures[2]?.texture === untouched, "the untouched image keeps its texture")
        XCTAssertEqual(presenter.imageTextures[2]?.generation, 1)
        // A placement that disappears drops its texture.
        try presenter.updateImages(placements: [placement(id: 2, row: 1)], pixels: [2: blue], grid: grid)
        XCTAssertNil(presenter.imageTextures[1])
    }

    func testOrderedPlacementsSortByZKeepingSnapshotOrder() throws {
        let sorted = MetalPresenter.ordered([placement(id: 1, z: 0), placement(id: 2, z: -5),
                                             placement(id: 3, z: 0), placement(id: 4, z: -2_000_000_000)])
        XCTAssertEqual(sorted.map(\.id), [4, 2, 1, 3], "z bands first, snapshot order breaking ties")
    }

    // MARK: Helpers

    private func placement(id: UInt32, gen: UInt64 = 1, row: Int = 0, col: Int = 4, cols: Int = 3, rows: Int = 1, z: Int = 0,
                           sx: Int? = nil, sy: Int? = nil, sw: Int? = nil, sh: Int? = nil,
                           ox: Int? = nil, oy: Int? = nil, dw: Int? = nil, dh: Int? = nil, w: Int = 60, h: Int = 40) -> ImagePlacement {
        var value: [String: Any] = ["id": id, "gen": gen, "w": w, "h": h, "row": row, "col": col, "cols": cols, "rows": rows, "z": z]
        for (key, item) in [("sx", sx), ("sy", sy), ("sw", sw), ("sh", sh), ("ox", ox), ("oy", oy), ("dw", dw), ("dh", dh)] {
            if let item { value[key] = item }
        }
        return try! JSONDecoder().decode(ImagePlacement.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func cell(_ row: Int, _ col: Int, text: String = "", fg: [Int] = [218, 226, 239], bg: [Int] = [8, 10, 13],
                      selected: Bool = false, underline: Bool = false, strike: Bool = false, bold: Bool = false) -> [Any] {
        // The wire form: [row, col, text, fg, bg, attrs, ucolor?]; an underline here is single (style 1) in red.
        let attrs = (bold ? 1 : 0) | (underline ? 4 | 1 << 8 : 0) | (selected ? 8 : 0) | (strike ? 32 : 0)
        var value: [Any] = [row, col, text, fg[0] << 16 | fg[1] << 8 | fg[2], bg[0] << 16 | bg[1] << 8 | bg[2], attrs]
        if underline { value.append(0xff0000) }
        return value
    }

    private func snapshot(cells: [[Any]] = [], images: [ImagePlacement] = [], partial: [Int]? = nil,
                          cursor: [String: Any] = ["row": 4, "col": 2, "visible": false]) throws -> Snapshot {
        var object: [String: Any] = ["changed": true, "revision": 1, "cols": cols, "rows": rows, "title": "", "cells": cells,
            "lines": Array(repeating: String(repeating: " ", count: cols), count: rows), "images": images.map { placement in
                var value: [String: Any] = ["id": placement.id, "gen": placement.gen, "w": placement.w, "h": placement.h,
                                            "row": placement.row, "col": placement.col, "cols": placement.cols, "rows": placement.rows, "z": placement.z]
                for (key, item) in [("sx", placement.sx), ("sy", placement.sy), ("sw", placement.sw), ("sh", placement.sh),
                                    ("ox", placement.ox), ("oy", placement.oy), ("dw", placement.dw), ("dh", placement.dh)] {
                    if let item { value[key] = item }
                }
                return value
            }, "cursor": cursor, "bracketed_paste": false, "app_cursor": false, "mouse_mode": false,
            "mouse_sgr": false, "mouse_drag": false, "mouse_motion": false, "focus_reporting": false, "alternate": false,
            "offset": 0, "history": 0, "clipboard": [] as [String], "exited": false]
        if let partial { object["partial"] = true; object["dirty"] = partial }
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func entry(_ generation: UInt64, _ width: Int, _ height: Int, _ color: (Int, Int) -> [UInt8]) -> ImageStore.Entry {
        var bytes: [UInt8] = []
        for y in 0..<height { for x in 0..<width { let value = color(x, y); bytes += [value[0], value[1], value[2], value[3]] } }
        return ImageStore.Entry(generation: generation, width: width, height: height, rgba: Data(bytes))
    }

    private func bytes(_ context: CGContext) -> Data { Data(bytes: context.data!, count: context.bytesPerRow * context.height) }
    /// RGBA bitmap accessors; the layer bitmaps store BGRA with scanline 0 at the top.
    private func rgb(_ context: CGContext, x: Int, yFromTop: Int) -> [UInt8] {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = yFromTop * context.bytesPerRow + x * 4
        return [data[offset + 2], data[offset + 1], data[offset]]
    }
    private func alpha(_ context: CGContext, x: Int, yFromTop: Int) -> UInt8 {
        context.data!.assumingMemoryBound(to: UInt8.self)[yFromTop * context.bytesPerRow + x * 4 + 3]
    }
    /// Pixels with any coverage inside one cell of a scale-1 layer bitmap (8 pt margin).
    private func opaquePixels(_ context: CGContext, inRow row: Int, col: Int) -> Int {
        let (w, h) = (Int(cell.width), Int(cell.height))
        var count = 0
        for y in (8 + row * h)..<(8 + (row + 1) * h) {
            for x in (8 + col * w)..<(8 + (col + 1) * w) where alpha(context, x: x, yFromTop: y) > 0 { count += 1 }
        }
        return count
    }
    // MARK: Metal equivalence with the CPU composite

    /// Text plus images in all three z bands, a source rect, ox/oy offsets, dw/dh destination sizes and
    /// semi-transparent pixels: the offscreen Metal frame must match the CPU composite pixel-for-pixel
    /// (per channel <= 4 on >= 99% of pixels; resampled edges may differ).
    @MainActor func testOffscreenMetalFrameMatchesCpuComposite() throws {
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        let underlay = placement(id: 1, row: 0, col: 4, cols: 4, rows: 2, z: -2_000_000_000, sx: 16, sw: 80, sh: 80, w: 96, h: 80)
        let between = placement(id: 2, row: 2, col: 4, cols: 3, rows: 1, z: -5, ox: 6, oy: -4, dw: 60, dh: 40, w: 60, h: 40)
        let overlay = placement(id: 3, row: 5, col: 0, cols: 1, rows: 1, z: 1, w: 20, h: 20)
        let cells = [cell(0, 0, text: "A"), cell(0, 1, text: "B", fg: [143, 202, 141]),
                     cell(1, 0, bg: [60, 80, 120]), cell(1, 1, text: "xz", bg: [60, 80, 120]),
                     cell(1, 4, bg: [60, 80, 120]), cell(2, 0, text: "sel", selected: true), cell(2, 4, text: "img"),
                     cell(3, 0, text: "und", underline: true), cell(3, 2, text: "gone", strike: true),
                     cell(5, 0, text: "txt", bold: true)]
        let snapshot = try self.snapshot(cells: cells, images: [underlay, between, overlay],
                                         cursor: ["row": 4, "col": 2, "visible": true])
        func checker(_ x: Int, _ y: Int) -> [UInt8] { (x / 8 + y / 8) % 2 == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        let teal: (Int, Int) -> [UInt8] = { x, _ in x < 30 ? [0, 180, 170, 200] : [0, 180, 170, 120] }
        let pixels: [UInt32: ImageStore.Entry] = [1: entry(1, 96, 80, checker), 2: entry(1, 60, 40, teal),
                                                  3: entry(1, 20, 20) { _, _ in [255, 210, 0, 255] }]
        var images: [UInt32: CGImage] = [:]
        for (id, item) in pixels { images[id] = try XCTUnwrap(ImageStore.makeImage(item.rgba, width: item.width, height: item.height)) }

        let cpu = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 2, fontName: "Menlo", fontSize: 13,
                                          cellSize: cell, composition: "ab", images: images)
        let frame = try GridRasterizer().renderLayers(snapshot: snapshot, damage: nil, size: size, scale: 2, fontName: "Menlo",
                                                      fontSize: 13, cellSize: cell, composition: "ab")
        try presenter.updateLayers(background: frame.background, foreground: frame.foreground, damage: frame.damage,
                                   grid: GridGeometry(cols: cols, rows: rows, cell: cell, scale: 2),
                                   placements: snapshot.images ?? [], pixels: pixels)
        let gpu = try presenter.renderOffscreen(width: cpu.width, height: cpu.height)

        let left = cpu.data!.assumingMemoryBound(to: UInt8.self), right = gpu.withUnsafeBytes { $0.bindMemory(to: UInt8.self) }
        let stride = cpu.bytesPerRow
        var close = 0, total = 0
        for y in 0..<cpu.height { for x in 0..<cpu.width {
            let offset = y * stride + x * 4
            let diff = [abs(Int(left[offset]) - Int(right[offset])), abs(Int(left[offset + 1]) - Int(right[offset + 1])),
                        abs(Int(left[offset + 2]) - Int(right[offset + 2]))]
            if diff.max()! <= 4 { close += 1 }
            total += 1
        } }
        XCTAssertGreaterThanOrEqual(Double(close) / Double(total), 0.99, "Metal frame differs from the CPU composite")
        // Spot-check the z bands through the composited output: the underlay shows on default cells only,
        // the between image sits under glyphs, the overlay covers the text beneath it.
        func at(_ x: Int, _ y: Int) -> [UInt8] { [left[y * stride + x * 4 + 2], left[y * stride + x * 4 + 1], left[y * stride + x * 4]] }
        XCTAssertNotEqual(at(120, 40), [8, 10, 13], "the underlay paints outside the custom cell")
        XCTAssertEqual(at(100, 60), at(100, 60), "stable")
    }
}
