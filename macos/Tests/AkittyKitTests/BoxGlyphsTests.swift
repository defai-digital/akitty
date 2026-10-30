import XCTest
@testable import AkittyKit

final class BoxGlyphsTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 16)
    private let scales = [1, 2]

    private enum Edge { case top, bottom, left, right }

    func testStackedLightAndHeavyVerticalsJoinWithoutGaps() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale, light = scale
            let lightX = (w - light) / 2
            let thin = GlyphBitmap(rows: ["│", "│", "│"], cell: cell, scale: scale)
            let thick = GlyphBitmap(rows: ["┃", "┃", "┃"], cell: cell, scale: scale)
            for row in 0..<3 {
                for y in 0..<h {
                    for x in lightX..<(lightX + light) {
                        XCTAssertTrue(thin.painted(row: row, col: 0, x: x, y: y), "│ row \(row) @\(scale)x")
                    }
                }
            }
            XCTAssertFalse(thin.painted(row: 1, col: 0, x: lightX - 1, y: h / 2), "left of │ @\(scale)x")
            XCTAssertFalse(thin.painted(row: 1, col: 0, x: lightX + light, y: h / 2), "right of │ @\(scale)x")
            let heavyX = (w - 2 * light) / 2
            for row in 0..<3 {
                for y in 0..<h {
                    for x in heavyX..<(heavyX + 2 * light) {
                        XCTAssertTrue(thick.painted(row: row, col: 0, x: x, y: y), "┃ row \(row) @\(scale)x")
                    }
                }
            }
            let thinRun = (0..<w).filter { thin.painted(row: 1, col: 0, x: $0, y: h / 2) }.count
            let thickRun = (0..<w).filter { thick.painted(row: 1, col: 0, x: $0, y: h / 2) }.count
            XCTAssertGreaterThan(thickRun, thinRun, "┃ thicker than │ @\(scale)x")
        }
    }

    func testHorizontalLinesRunAcrossCellsAndDoubleLineSplitsInTwo() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale, light = scale
            for glyph in ["─", "━"] {
                let bitmap = GlyphBitmap(rows: [String(repeating: glyph, count: 3)], cell: cell, scale: scale)
                let t = glyph == "━" ? 2 * light : light
                let top = (h - t) / 2, origin = bitmap.origin(row: 0, col: 0)
                for x in origin.x..<(origin.x + 3 * w) {
                    for dy in 0..<t {
                        XCTAssertGreaterThanOrEqual(bitmap.value(x: x, y: origin.y + top + dy), 128, "\(glyph) @\(scale)x")
                    }
                }
            }
            let double = GlyphBitmap(rows: ["═══"], cell: cell, scale: scale)
            let origin = double.origin(row: 0, col: 0), top = (h - 3 * light) / 2
            for x in origin.x..<(origin.x + 3 * w) {
                for dy in 0..<light {
                    XCTAssertGreaterThanOrEqual(double.value(x: x, y: origin.y + top + dy), 128, "═ upper @\(scale)x")
                    XCTAssertGreaterThanOrEqual(double.value(x: x, y: origin.y + top + 2 * light + dy), 128, "═ lower @\(scale)x")
                    XCTAssertEqual(double.value(x: x, y: origin.y + top + light + dy), 0, "═ gap @\(scale)x")
                }
            }
        }
    }

    func testEachArmReachesOnlyTheEdgesItConnects() {
        // Corners connect two edges, tees three and the cross four; the remaining edges must stay clear.
        let cases: [(String, [Edge])] = [
            ("┼", [.top, .bottom, .left, .right]),
            ("├", [.top, .bottom, .right]),
            ("┤", [.top, .bottom, .left]),
            ("┬", [.bottom, .left, .right]),
            ("┴", [.top, .left, .right]),
            ("┌", [.bottom, .right]),
            ("┐", [.bottom, .left]),
            ("└", [.top, .right]),
            ("┘", [.top, .left]),
        ]
        for scale in scales {
            for (glyph, connected) in cases {
                let bitmap = GlyphBitmap(rows: [glyph], cell: cell, scale: scale)
                for edge in [Edge.top, .bottom, .left, .right] {
                    let coverage = edgeCoverage(bitmap, scale: scale, edge)
                    if connected.contains(edge) {
                        XCTAssertEqual(coverage, 1, accuracy: 0.01, "\(glyph) \(edge) @\(scale)x")
                    } else {
                        XCTAssertLessThan(coverage, 0.01, "\(glyph) \(edge) @\(scale)x")
                    }
                }
            }
        }
    }

    func testMixedWeightTeeKeepsEachArmItsOwnThickness() {
        // ┍ is DOWN LIGHT AND RIGHT HEAVY: the right arm is heavier than the down arm.
        for scale in scales {
            let w = 8 * scale, h = 16 * scale, light = scale
            let bitmap = GlyphBitmap(rows: ["┍"], cell: cell, scale: scale)
            let down = (0..<w).filter { bitmap.painted(row: 0, col: 0, x: $0, y: h - light) }.count
            let right = (0..<h).filter { bitmap.painted(row: 0, col: 0, x: w - light, y: $0) }.count
            XCTAssertEqual(down, light, "down light @\(scale)x")
            XCTAssertEqual(right, 2 * light, "right heavy @\(scale)x")
            XCTAssertGreaterThan(right, down, "right thicker @\(scale)x")
        }
    }

    /// Mean brightness over a light-stroke-sized box centred on one edge.
    private func edgeCoverage(_ bitmap: GlyphBitmap, scale: Int, _ edge: Edge) -> Double {
        let w = 8 * scale, h = 16 * scale, light = scale
        let x = (w - light) / 2, y = (h - light) / 2
        switch edge {
        case .top: return bitmap.coverage(row: 0, col: 0, x: x..<(x + light), y: 0..<light)
        case .bottom: return bitmap.coverage(row: 0, col: 0, x: x..<(x + light), y: (h - light)..<h)
        case .left: return bitmap.coverage(row: 0, col: 0, x: 0..<light, y: y..<(y + light))
        case .right: return bitmap.coverage(row: 0, col: 0, x: (w - light)..<w, y: y..<(y + light))
        }
    }

    /// Painted runs and gaps along a scanline, so dashes can be checked without assuming where they land.
    private func runs(in pixels: [Bool]) -> (painted: Int, gaps: Int) {
        var painted = 0, gaps = 0, previous = false
        for pixel in pixels {
            if pixel && !previous { painted += 1 }
            if !pixel && previous { gaps += 1 }
            previous = pixel
        }
        return (painted, gaps)
    }

    func testRoundedCornersJoinTwoEdgesAndKeepTheJunctionPainted() {
        let cases: [(String, Edge, Edge, Edge, Edge)] = [
            ("╭", .bottom, .right, .top, .left),
            ("╮", .bottom, .left, .top, .right),
            ("╯", .top, .left, .bottom, .right),
            ("╰", .top, .right, .bottom, .left),
        ]
        for scale in scales {
            let w = 8 * scale, h = 16 * scale
            for (glyph, first, second, missingOne, missingTwo) in cases {
                let bitmap = GlyphBitmap(rows: [glyph], cell: cell, scale: scale)
                XCTAssertGreaterThan(edgeCoverage(bitmap, scale: scale, first), 0.2, "\(glyph) \(first) @\(scale)x")
                XCTAssertGreaterThan(edgeCoverage(bitmap, scale: scale, second), 0.2, "\(glyph) \(second) @\(scale)x")
                XCTAssertLessThan(edgeCoverage(bitmap, scale: scale, missingOne), 0.01, "\(glyph) \(missingOne) @\(scale)x")
                XCTAssertLessThan(edgeCoverage(bitmap, scale: scale, missingTwo), 0.01, "\(glyph) \(missingTwo) @\(scale)x")
                let middle = bitmap.coverage(row: 0, col: 0, x: (w / 4)..<(3 * w / 4), y: (h / 4)..<(3 * h / 4))
                XCTAssertGreaterThan(middle, 0.02, "\(glyph) junction @\(scale)x")
            }
        }
    }

    func testDashesLeaveGapsAlongTheMiddleOfTheLine() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale, light = scale
            let horizontal = GlyphBitmap(rows: ["┄"], cell: cell, scale: scale)
            let row = (h - light) / 2
            let horizontalRuns = runs(in: (0..<w).map { horizontal.painted(row: 0, col: 0, x: $0, y: row) })
            XCTAssertGreaterThan(horizontalRuns.painted, 1, "┄ runs @\(scale)x")
            XCTAssertGreaterThan(horizontalRuns.gaps, 0, "┄ gaps @\(scale)x")
            let vertical = GlyphBitmap(rows: ["┆"], cell: cell, scale: scale)
            let column = (w - light) / 2
            let verticalRuns = runs(in: (0..<h).map { vertical.painted(row: 0, col: 0, x: column, y: $0) })
            XCTAssertGreaterThan(verticalRuns.painted, 1, "┆ runs @\(scale)x")
            XCTAssertGreaterThan(verticalRuns.gaps, 0, "┆ gaps @\(scale)x")
        }
    }

    func testDiagonalsPaintOnlyTheirOwnCornerAreas() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale
            let quarters = [(0..<(w / 2), 0..<(h / 2)), ((w / 2)..<w, 0..<(h / 2)),
                            (0..<(w / 2), (h / 2)..<h), ((w / 2)..<w, (h / 2)..<h)]  // top-left, top-right, bottom-left, bottom-right
            func corners(_ glyph: String) -> [Double] {
                let bitmap = GlyphBitmap(rows: [glyph], cell: cell, scale: scale)
                return quarters.map { bitmap.coverage(row: 0, col: 0, x: $0.0, y: $0.1) }
            }
            let up = corners("╱")
            XCTAssertGreaterThan(up[2], 0.02, "╱ bottom-left @\(scale)x")
            XCTAssertGreaterThan(up[1], 0.02, "╱ top-right @\(scale)x")
            XCTAssertLessThan(up[0], 0.05, "╱ top-left @\(scale)x")
            let down = corners("╲")
            XCTAssertGreaterThan(down[0], 0.02, "╲ top-left @\(scale)x")
            XCTAssertGreaterThan(down[3], 0.02, "╲ bottom-right @\(scale)x")
            XCTAssertLessThan(down[2], 0.05, "╲ bottom-left @\(scale)x")
            for (index, value) in corners("╳").enumerated() {
                XCTAssertGreaterThan(value, 0.02, "╳ corner \(index) @\(scale)x")
            }
        }
    }

    func testEveryCodePointInTheBlockStaysInsideItsCell() {
        for scale in scales {
            for code in UInt32(0x2500)...UInt32(0x257F) {
                guard let scalar = Unicode.Scalar(code) else { return XCTFail("U+\(String(code, radix: 16))") }
                let bitmap = GlyphBitmap(rows: [String(scalar)], cell: cell, scale: scale)
                XCTAssertTrue(bitmap.padIsEmpty, "U+\(String(code, radix: 16)) @\(scale)x")
            }
        }
    }
    /// Double tees and the cross: the wall on a side with an arm is cut at the crossing arm, the other wall runs through.
    func testDoubleTeesAndCrossTurnTheirWallsInsteadOfClosingTheGap() {
        let size = CGSize(width: 12, height: 24), scale = 2           // 24x48 px, light stroke 3, bands 3 + 3 + 3
        let leftWall = 8, rightWall = 14, topWall = 20, bottomWall = 26, gapX = 11, gapY = 23, far = 21, farY = 44
        func lit(_ bitmap: GlyphBitmap, _ x: Int, _ y: Int) -> Bool { bitmap.painted(row: 0, col: 0, x: x, y: y) }

        let tee = GlyphBitmap(rows: ["╠"], cell: size, scale: scale)      // up, down, right
        XCTAssertTrue(lit(tee, leftWall, gapY), "╠ left wall runs straight through")
        XCTAssertFalse(lit(tee, rightWall, gapY), "╠ right wall is cut where the right arm leaves")
        XCTAssertTrue(lit(tee, rightWall, 2) && lit(tee, rightWall, farY), "╠ right wall continues above and below")
        XCTAssertTrue(lit(tee, far, topWall) && lit(tee, far, bottomWall), "╠ arm walls reach the right edge")
        XCTAssertFalse(lit(tee, far, gapY), "╠ gap between the arm walls stays open")
        XCTAssertFalse(lit(tee, gapX, gapY), "╠ centre gap stays open")

        let down = GlyphBitmap(rows: ["╦"], cell: size, scale: scale)     // down, left, right
        XCTAssertTrue(lit(down, 2, topWall) && lit(down, far, topWall), "╦ top wall runs across")
        XCTAssertTrue(lit(down, 2, bottomWall) && lit(down, far, bottomWall), "╦ bottom wall turns down on each side")
        XCTAssertFalse(lit(down, gapX, bottomWall), "╦ bottom wall is open where the down arm leaves")
        XCTAssertTrue(lit(down, leftWall, farY) && lit(down, rightWall, farY), "╦ both walls continue down")
        XCTAssertFalse(lit(down, gapX, gapY), "╦ centre gap stays open")

        let cross = GlyphBitmap(rows: ["╬"], cell: size, scale: scale)
        for (x, y) in [(leftWall, 2), (leftWall, farY), (rightWall, 2), (rightWall, farY), (2, topWall), (far, topWall), (2, bottomWall), (far, bottomWall)] {
            XCTAssertTrue(lit(cross, x, y), "╬ wall at \(x),\(y)")
        }
        for (x, y) in [(leftWall, gapY), (rightWall, gapY), (gapX, topWall), (gapX, bottomWall), (gapX, gapY), (2, gapY), (far, gapY), (gapX, 2), (gapX, farY)] {
            XCTAssertFalse(lit(cross, x, y), "╬ gap at \(x),\(y)")
        }
    }
}
