import XCTest
@testable import AkittyKit

final class HotpathProbe: XCTestCase {
    func time(_ label: String, _ n: Int, _ body: () throws -> Void) rethrows {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { try body() }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(n)
        print("PROBE \(label): \(String(format: "%.2f", ms)) ms")
    }
    /// Opt-in benchmark: `AKITTY_HOTPATH_PROBE=1 AKITTY_RUST_LIB_DIR=<repo>/target/release swift test -c release --filter HotpathProbe`.
    func testProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AKITTY_HOTPATH_PROBE"] == "1", "benchmark")
        let cols = 200, rows = 50
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        var text = "\u{1b}[H"
        for r in 0..<rows {
            text += "\u{1b}[\(r + 1);1H\u{1b}[3\(r % 7 + 1)m"
            for c in 0..<cols { text.unicodeScalars.append(UnicodeScalar(UInt8(97 + (r + c) % 26))) }
        }
        _ = try session.call("feed", ["text": text])
        try time("raw CoreBridge.call(snapshot) incl. parse+reserialize", 30) { _ = try session.call("snapshot") }
        try time("session.snapshot() (single-pass decode)", 30) { _ = try session.snapshot() }
        let snapshot = try XCTUnwrap(try session.snapshot())
        let data = try session.call("snapshot")
        try time("JSONDecoder.decode(Snapshot) alone", 30) { _ = try JSONDecoder().decode(Snapshot.self, from: data) }
        let cell = CGSize(width: 8, height: 18), size = CGSize(width: 1616, height: 916)
        try time("GridRasterizer.make 200x50 @2x", 20) {
            _ = try GridRasterizer.make(snapshot: snapshot, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        }
        // The typing case: one changed row on a full screen, held snapshot as the baseline.
        var held = try XCTUnwrap(try session.snapshot())
        var toggle = 0
        try time("typing one character on a full screen: snapshot(since:base:)", 50) {
            toggle += 1
            _ = try session.call("feed", ["text": "\u{1b}[1;1H\(toggle % 2 == 0 ? "x" : "y")"])
            held = try XCTUnwrap(try session.snapshot(since: held.revision, base: held))
        }
        // Persistent rasterizer: a full frame, then a typing frame that repaints one row.
        let stateful = GridRasterizer()
        var typed = try XCTUnwrap(try session.snapshot())
        _ = try stateful.render(snapshot: typed, damage: nil, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        try time("GridRasterizer.render full (warm glyph cache)", 20) {
            _ = try stateful.render(snapshot: typed, damage: nil, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        }
        var frame = try stateful.render(snapshot: typed, damage: [], size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        var flip = 0
        try time("GridRasterizer.render typing frame (1 row)", 50) {
            flip += 1
            _ = try session.call("feed", ["text": "\u{1b}[1;1H\(flip % 2 == 0 ? "x" : "y")"])
            typed = try XCTUnwrap(try session.snapshot(since: typed.revision, base: typed))
            frame = try stateful.render(snapshot: typed, damage: Set(typed.dirty ?? []), size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        }
        try MainActor.assumeIsolated {
            guard let presenter = try? MetalPresenter() else { return }
            try presenter.update(bitmap: frame.context, damage: nil)
            try time("MetalPresenter.update full upload", 30) { try presenter.update(bitmap: frame.context, damage: nil) }
            let rows = 0..<Int(18 * 2 + 16)
            try time("MetalPresenter.update one-row damage", 30) { try presenter.update(bitmap: frame.context, damage: rows) }
        }
        // Mostly blank screen with a cursor line, the usual shell case.
        let quiet = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? quiet.close() }
        _ = try quiet.call("feed", ["text": "$ ls -la\r\ntotal 8\r\n$ "])
        let small = try XCTUnwrap(try quiet.snapshot())
        try time("session.snapshot() mostly blank", 30) { _ = try quiet.snapshot() }
        try time("GridRasterizer.make mostly blank", 20) {
            _ = try GridRasterizer.make(snapshot: small, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        }
    }
}
