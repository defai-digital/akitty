import XCTest
import CoreGraphics
import Metal
@testable import AkittyKit

/// Releasing a background tab's window-sized pixels: the rasterizer drops its bitmaps and the presenter its textures,
/// and the next frame is a full repaint/upload.
final class BackgroundTabMemoryTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 18)
    private let cols = 40, rows = 12
    private var size: CGSize { CGSize(width: CGFloat(cols) * cell.width + 16, height: CGFloat(rows) * cell.height + 16) }

    /// An empty grid: its unchanged frame has no cursor row to add to the damage set, so the empty range is
    /// observable. The bitmap itself is still window-sized, which is what retention is about.
    func testReleasedFramesForceAFullRepaint() throws {
        let snapshot = try snapshot(rows: 0, cols: 1)
        let rasterizer = GridRasterizer()
        let first = try rasterizer.render(snapshot: snapshot, damage: nil, size: size, scale: 2, fontName: "Menlo",
                                          fontSize: 13, cellSize: cell, composition: "", reuse: true)
        XCTAssertNil(first.damage, "the first frame is a full repaint")

        let reused = try rasterizer.render(snapshot: snapshot, damage: [], size: size, scale: 2, fontName: "Menlo",
                                           fontSize: 13, cellSize: cell, composition: "", reuse: true)
        XCTAssertEqual(reused.damage, 0..<0, "an unchanged frame reuses the retained bitmap")
        XCTAssertTrue(reused.context === first.context, "the bitmap was kept between frames")

        rasterizer.releaseFrames()

        let afterRelease = try rasterizer.render(snapshot: snapshot, damage: [], size: size, scale: 2, fontName: "Menlo",
                                                 fontSize: 13, cellSize: cell, composition: "", reuse: true)
        XCTAssertNil(afterRelease.damage, "nothing was retained, so the next frame repaints in full")
        XCTAssertFalse(afterRelease.context === first.context, "a fresh window-sized bitmap was allocated")
    }

    @MainActor func testReleasedTexturesAreRecreatedOnTheNextUpload() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let presenter: MetalPresenter
        do { presenter = try MetalPresenter() } catch { throw XCTSkip("Metal unavailable: \(error)") }
        try presenter.update(bitmap: try bitmap())
        XCTAssertNotNil(presenter.texture, "the upload allocates a texture")

        presenter.releaseTextures()

        XCTAssertNil(presenter.texture)
        XCTAssertFalse(presenter.layered)
        XCTAssertTrue(presenter.imageTextures.isEmpty)

        try presenter.update(bitmap: try bitmap())
        XCTAssertNotNil(presenter.texture, "the next upload reallocates a texture")
    }

    // MARK: Helpers

    private func bitmap() throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    }

    private func snapshot(rows: Int = 3, cols: Int = 6) throws -> Snapshot {
        let object: [String: Any] = ["changed": true, "revision": 1, "cols": cols, "rows": rows, "title": "",
            "cells": [] as [[String: Any]], "lines": Array(repeating: String(repeating: " ", count: cols), count: rows),
            "cursor": ["row": 0, "col": 0, "visible": false], "bracketed_paste": false, "app_cursor": false,
            "mouse_mode": false, "mouse_sgr": false, "mouse_drag": false, "mouse_motion": false, "focus_reporting": false,
            "alternate": false, "offset": 0, "history": 0, "clipboard": [] as [String], "exited": false]
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
