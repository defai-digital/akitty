import XCTest
@testable import AkittyKit

/// Native snapshot transport measurement: the full `TerminalSession.snapshot()` path
/// (core call + cell decode), median of 50 runs on a dense headless screen, for both
/// the JSON cells and the negotiated binary block.
/// Opt in with `AKITTY_PERF=1`; build the core release library and point Swift at it:
///   cargo build --release --locked -p akitty-core
///   AKITTY_PERF=1 AKITTY_RUST_LIB_DIR=<repo>/target/release swift test -c release --filter CellTransportPerf
final class CellTransportPerf: XCTestCase {
    /// Same dense screen the Rust probe feeds: every cell styled, with periodic
    /// wide/CJK, combining, underline-colour and OSC 8 link cells.
    private func denseRow(_ row: Int, _ cols: Int) -> String {
        var s = "\u{1b}[\(row + 1);1H"
        var col = 0
        while col < cols {
            let n = row * cols + col
            s += "\u{1b}[0m"
            switch n % 8 {
            case 0: s += "\u{1b}[31m"
            case 1: s += "\u{1b}[32m"
            case 2: s += "\u{1b}[33m"
            case 3: s += "\u{1b}[34m"
            case 4: s += "\u{1b}[38;2;10;200;30m"
            case 5: s += "\u{1b}[4m\u{1b}[58;2;200;10;10m\u{1b}[35m"
            case 6: s += "\u{1b}[48;2;1;2;3m\u{1b}[37m"
            default: s += "\u{1b}[36m"
            }
            let linked = n % 10 == 0
            if linked { s += "\u{1b}]8;;https://example.test/\((n / 10) % 4)\u{1b}\\" }
            if n % 23 == 5 && col + 1 < cols {
                s.append("界")
                col += 2
            } else if n % 37 == 11 {
                s += "e\u{301}"
                col += 1
            } else {
                s.append(Character(UnicodeScalar(UInt8(97 + n % 26))))
                col += 1
            }
            if linked { s += "\u{1b}]8;;\u{1b}\\" }
        }
        return s
    }

    private func feedDense(_ session: TerminalSession, cols: Int, rows: Int) throws {
        for row in 0..<rows { _ = try session.call("feed", ["text": denseRow(row, cols)]) }
    }

    private func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private func report(_ label: String, _ samples: [Double]) {
        print(String(format: "PERF %@: %.2f ms median, %.2f ms min (50 runs)", label, median(samples), samples.min() ?? 0))
    }

    func testCellTransportPerf() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AKITTY_PERF"] == "1", "benchmark")
        // 400x100 is 40,000 cells; the core caps a screen at 32,768, so 400x80 is the
        // nearest valid dense screen (the same cap the Rust probe reports).
        for (cols, rows) in [(200, 50), (400, 80)] {
            let session = try TerminalSession(cols: cols, rows: rows, headless: true)
            defer { try? session.close() }
            try feedDense(session, cols: cols, rows: rows)
            for binary in [false, true] {
                let transport = binary ? "binary cells" : "JSON cells"
                var full: [Double] = []
                for _ in 0..<50 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = try session.snapshot(since: nil, base: nil, binary: binary)
                    full.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                }
                report("full \(cols)x\(rows) \(transport)", full)
                // The typing case: five dirty rows per snapshot, feed excluded from the timing.
                var held = try XCTUnwrap(try session.snapshot(since: nil, base: nil, binary: binary))
                var partial: [Double] = []
                for i in 0..<50 {
                    var feed = ""
                    for r in 0..<5 { feed += "\u{1b}[\(r + 1);1H\u{1b}[31m\(i % 2 == 0 ? "x" : "y")" }
                    _ = try session.call("feed", ["text": feed])
                    let start = DispatchTime.now().uptimeNanoseconds
                    held = try XCTUnwrap(try session.snapshot(since: held.revision, base: held, binary: binary))
                    partial.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                }
                report("partial \(cols)x\(rows) 5 dirty rows \(transport)", partial)
            }
        }
    }
}
