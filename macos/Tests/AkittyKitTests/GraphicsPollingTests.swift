import XCTest
import CoreGraphics
@testable import AkittyKit

/// Round-2 Swift side: destination sizes, the animating flag and the display-rate polling decision.
final class GraphicsPollingTests: XCTestCase {
    // MARK: Decoding

    func testImagePlacementDecodesDestinationSize() throws {
        let json = Data(#"{"id":7,"gen":3,"w":40,"h":30,"row":1,"col":2,"cols":3,"rows":4,"z":0,"dw":12,"dh":9}"#.utf8)
        let value = try JSONDecoder().decode(ImagePlacement.self, from: json)
        XCTAssertEqual([value.dw, value.dh], [12, 9])
    }

    func testImagePlacementDecodesOldSnapshotsWithoutDestinationSize() throws {
        let json = Data(#"{"id":9,"gen":1,"w":40,"h":30,"row":0,"col":1,"cols":2,"rows":1,"z":0,"ox":4,"oy":-3}"#.utf8)
        let value = try JSONDecoder().decode(ImagePlacement.self, from: json)
        XCTAssertNil(value.dw); XCTAssertNil(value.dh)
        XCTAssertEqual(value.sourceRect, CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    func testSnapshotDecodesTheAnimatingFlagAndDefaultsToNil() throws {
        XCTAssertEqual(try snapshot(["animating": true]).animating, true)
        XCTAssertEqual(try snapshot(["animating": false]).animating, false)
        XCTAssertNil(try snapshot().animating, "snapshots from older cores have no animating field")
    }

    // MARK: Rasterizer

    func testRasterizerDrawsOnlyTheDestinationSizeInsideTheCells() throws {
        // 16x16 red image placed over a 2x2 cell block but limited to 16x16 device pixels: it covers
        // the top-left corner of the block only.
        let placement: [String: Any] = ["id": 1, "gen": 1, "w": 16, "h": 16, "row": 0, "col": 0, "cols": 2, "rows": 2, "z": 0, "dw": 16, "dh": 16]
        let context = try rasterize(try snapshot(["images": [placement]]), scale: 1, images: [1: try redImage()])
        XCTAssertEqual(sample(context, x: 12, yFromTop: 12), [255, 0, 0], "the fragment paints its own rectangle")
        XCTAssertEqual(sample(context, x: 26, yFromTop: 12), try background(), "dw stops short of the second cell")
        XCTAssertEqual(sample(context, x: 12, yFromTop: 40), try background(), "dh stops short of the second cell row")
        // Without dw/dh the same placement fills the whole 2x2 block.
        var full = placement; full["dw"] = nil; full["dh"] = nil
        let unbounded = try rasterize(try snapshot(["images": [full]]), scale: 1, images: [1: try redImage()])
        XCTAssertEqual(sample(unbounded, x: 26, yFromTop: 40), [255, 0, 0])
    }

    func testRasterizerDestinationSizeIsInDevicePixels() throws {
        // At scale 2 the same 16 device pixels are 8 points, so the fragment shrinks with the backing scale.
        let placement: [String: Any] = ["id": 1, "gen": 1, "w": 16, "h": 16, "row": 0, "col": 0, "cols": 2, "rows": 2, "z": 0, "dw": 16, "dh": 16]
        let context = try rasterize(try snapshot(["images": [placement]]), scale: 2, images: [1: try redImage()])
        XCTAssertEqual(sample(context, x: 20, yFromTop: 20), [255, 0, 0])
        XCTAssertEqual(sample(context, x: 40, yFromTop: 20), try background(scale: 2))
    }

    // MARK: Polling decision

    func testWantsFastPollingFollowsAnimationsAndRecentFrameChanges() {
        XCTAssertTrue(TerminalView.wantsFastPolling(animating: true, changedAt: 0, now: 500))
        XCTAssertTrue(TerminalView.wantsFastPolling(animating: false, changedAt: 100, now: 100.5), "a fresh frame still polls at display rate")
        XCTAssertFalse(TerminalView.wantsFastPolling(animating: false, changedAt: 100, now: 101), "idle for a second falls back to 30 Hz")
        XCTAssertFalse(TerminalView.wantsFastPolling(animating: false, changedAt: 0, now: 10), "nothing ever changed")
    }

    // MARK: Helpers

    private func snapshot(_ extra: [String: Any] = [:]) throws -> Snapshot {
        var object: [String: Any] = ["changed": true, "revision": 1, "cols": 6, "rows": 3, "title": "", "cells": [] as [[String: Any]],
            "lines": Array(repeating: String(repeating: " ", count: 6), count: 3), "links": [] as [String],
            "cursor": ["row": 0, "col": 0, "visible": false], "bracketed_paste": false, "app_cursor": false, "mouse_mode": false,
            "mouse_sgr": false, "mouse_drag": false, "mouse_motion": false, "focus_reporting": false, "alternate": false,
            "offset": 0, "history": 0, "clipboard": [] as [String], "exited": false]
        for (key, value) in extra { object[key] = value }
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func redImage() throws -> CGImage {
        try XCTUnwrap(ImageStore.makeImage(Data([UInt8]((0..<256).flatMap { _ in [255, 0, 0, 255] })), width: 16, height: 16))
    }

    private func rasterize(_ snapshot: Snapshot, scale: CGFloat, images: [UInt32: CGImage]) throws -> CGContext {
        try GridRasterizer.make(snapshot: snapshot, size: CGSize(width: 200, height: 120), scale: scale, fontName: "Menlo",
                                fontSize: 13, cellSize: CGSize(width: 10, height: 20), composition: "", images: images)
    }

    private func background(scale: CGFloat = 1) throws -> [UInt8] {
        sample(try rasterize(try snapshot(), scale: scale, images: [:]), x: Int(40 * scale), yFromTop: Int(40 * scale))
    }

    /// Samples a bitmap pixel from the top-left; CGBitmapContext stores scanline 0 at the top.
    private func sample(_ context: CGContext, x: Int, yFromTop: Int) -> [UInt8] {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = yFromTop * context.bytesPerRow + x * 4
        return [data[offset + 2], data[offset + 1], data[offset]]
    }
}
