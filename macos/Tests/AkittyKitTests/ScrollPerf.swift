import XCTest
@testable import AkittyKit

/// Controlled comparison of full raster and bitmap scroll using identical snapshots.
final class ScrollPerf: XCTestCase {
    func testScrollPerf() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AKITTY_PERF"] == "1", "benchmark")
        let cols = 200, rows = 50
        let session = try TerminalSession(cols: cols, rows: rows, headless: true)
        defer { try? session.close() }
        func line(_ number: Int) -> String {
            let prefix = String(format: "line %04d ", number)
            return prefix + String(repeating: "x", count: cols - prefix.count)
        }
        _ = try session.call("feed", ["text": (0..<rows).map { "\u{1b}[\($0 + 1);1H\u{1b}[32m" + line($0) }.joined()])
        let initial = try XCTUnwrap(try session.snapshot())
        var held = initial, snapshots: [Snapshot] = []
        for index in 0..<43 {
            _ = try session.call("feed", ["text": "\u{1b}[50;1H\r\n" + line(rows + index)])
            held = try XCTUnwrap(try session.snapshot(since: held.revision, base: held))
            XCTAssertEqual(held.shift, 1)
            snapshots.append(held)
        }
        let full = GridRasterizer(), scroll = GridRasterizer()
        let cell = CGSize(width: 8, height: 18), size = CGSize(width: 1616, height: 916)
        for renderer in [full, scroll] {
            _ = try renderer.render(snapshot: initial, damage: nil, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
        }
        var fullTimes: [Double] = [], scrollTimes: [Double] = []
        for (index, snapshot) in snapshots.enumerated() {
            var reference: GridRasterizer.Frame!, reused: GridRasterizer.Frame!
            func drawFull() throws {
                let start = DispatchTime.now().uptimeNanoseconds
                reference = try full.render(snapshot: snapshot, damage: nil, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
                if index >= 3 { fullTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
            }
            func drawScroll() throws {
                let start = DispatchTime.now().uptimeNanoseconds
                reused = try scroll.render(snapshot: snapshot, damage: Set(snapshot.dirty ?? []), scroll: snapshot.shift ?? 0, size: size, scale: 2, fontName: "Menlo", fontSize: 13, cellSize: cell, composition: "")
                if index >= 3 { scrollTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
            }
            if index.isMultiple(of: 2) { try drawFull(); try drawScroll() }
            else { try drawScroll(); try drawFull() }
            XCTAssertEqual(reused.scrolledRows, 1)
            let count = reference.context.bytesPerRow * reference.context.height
            XCTAssertEqual(Data(bytes: reused.context.data!, count: count), Data(bytes: reference.context.data!, count: count), "frame \(index)")
        }
        let report: [String: Any] = ["scope": "CPU raster only, 200x50 @2x, 3 warmups, 40 measured frames",
                                   "full_ms": fullTimes, "scroll_ms": scrollTimes]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("SCROLL_PERF \(String(decoding: data, as: UTF8.self))")
    }
}
