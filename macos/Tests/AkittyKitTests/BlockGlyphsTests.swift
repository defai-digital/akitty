import XCTest
@testable import AkittyKit

final class BlockGlyphsTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 16)
    private let scales = [1, 2]

    func testFullBlockFillsEveryPixel() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale
            let bitmap = GlyphBitmap(rows: ["█"], cell: cell, scale: scale)
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<w, y: 0..<h), 1, accuracy: 0.001, "scale \(scale)")
            XCTAssertTrue(bitmap.padIsEmpty, "scale \(scale)")
        }
    }

    func testUpperAndLowerHalvesTileTheCell() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale, mid = h / 2
            let bitmap = GlyphBitmap(rows: ["▀", "▄"], cell: cell, scale: scale)
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<w, y: 0..<mid), 1, accuracy: 0.001, "▀ top @\(scale)x")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<w, y: mid..<h), 0, accuracy: 0.001, "▀ bottom @\(scale)x")
            XCTAssertEqual(bitmap.coverage(row: 1, col: 0, x: 0..<w, y: 0..<mid), 0, accuracy: 0.001, "▄ top @\(scale)x")
            XCTAssertEqual(bitmap.coverage(row: 1, col: 0, x: 0..<w, y: mid..<h), 1, accuracy: 0.001, "▄ bottom @\(scale)x")
            XCTAssertTrue(bitmap.padIsEmpty, "scale \(scale)")
        }
    }

    func testUpperAndLowerHalvesTileOddHeightCells() {
        let odd = CGSize(width: 8, height: 15)
        for scale in scales {
            let w = 8 * scale, h = 15 * scale, mid = h / 2
            let bitmap = GlyphBitmap(rows: ["▀", "▄"], cell: odd, scale: scale)
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<w, y: 0..<mid), 1, accuracy: 0.001, "▀ top @\(scale)x")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<w, y: mid..<h), 0, accuracy: 0.001, "▀ bottom @\(scale)x")
            XCTAssertEqual(bitmap.coverage(row: 1, col: 0, x: 0..<w, y: 0..<mid), 0, accuracy: 0.001, "▄ top @\(scale)x")
            XCTAssertEqual(bitmap.coverage(row: 1, col: 0, x: 0..<w, y: mid..<h), 1, accuracy: 0.001, "▄ bottom @\(scale)x")
        }
    }

    func testLeftAndRightHalvesTileOddWidthCells() {
        let odd = CGSize(width: 9, height: 16)
        for scale in scales {
            let w = 9 * scale, h = 16 * scale, xm = w / 2
            let bitmap = GlyphBitmap(rows: ["▌▐"], cell: odd, scale: scale)
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<xm, y: 0..<h), 1, accuracy: 0.001, "▌ left @\(scale)x")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: xm..<w, y: 0..<h), 0, accuracy: 0.001, "▌ right @\(scale)x")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 1, x: 0..<xm, y: 0..<h), 0, accuracy: 0.001, "▐ left @\(scale)x")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 1, x: xm..<w, y: 0..<h), 1, accuracy: 0.001, "▐ right @\(scale)x")
            XCTAssertTrue(bitmap.padIsEmpty, "scale \(scale)")
        }
    }

    func testHalfAndEighthBlocksPaintExactPixelRanges() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale, xm = w / 2
            let eighthW = (w + 4) / 8, eighthH = (h + 4) / 8
            let left = GlyphBitmap(rows: ["▌"], cell: cell, scale: scale)
            XCTAssertEqual(left.coverage(row: 0, col: 0, x: 0..<xm, y: 0..<h), 1, accuracy: 0.001)
            XCTAssertEqual(left.coverage(row: 0, col: 0, x: xm..<w, y: 0..<h), 0, accuracy: 0.001)
            let right = GlyphBitmap(rows: ["▐"], cell: cell, scale: scale)
            XCTAssertEqual(right.coverage(row: 0, col: 0, x: 0..<xm, y: 0..<h), 0, accuracy: 0.001)
            XCTAssertEqual(right.coverage(row: 0, col: 0, x: xm..<w, y: 0..<h), 1, accuracy: 0.001)
            let bottom = GlyphBitmap(rows: ["▁"], cell: cell, scale: scale)
            XCTAssertEqual(bottom.coverage(row: 0, col: 0, x: 0..<w, y: 0..<h - eighthH), 0, accuracy: 0.001)
            XCTAssertEqual(bottom.coverage(row: 0, col: 0, x: 0..<w, y: h - eighthH..<h), 1, accuracy: 0.001)
            let top = GlyphBitmap(rows: ["▔"], cell: cell, scale: scale)
            XCTAssertEqual(top.coverage(row: 0, col: 0, x: 0..<w, y: 0..<eighthH), 1, accuracy: 0.001)
            XCTAssertEqual(top.coverage(row: 0, col: 0, x: 0..<w, y: eighthH..<h), 0, accuracy: 0.001)
            let leftEighth = GlyphBitmap(rows: ["▏"], cell: cell, scale: scale)
            XCTAssertEqual(leftEighth.coverage(row: 0, col: 0, x: 0..<eighthW, y: 0..<h), 1, accuracy: 0.001)
            XCTAssertEqual(leftEighth.coverage(row: 0, col: 0, x: eighthW..<w, y: 0..<h), 0, accuracy: 0.001)
        }
    }

    func testCheckerQuadrantPaintsOnlyUpperLeftAndLowerRight() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale, xm = w / 2, ym = h / 2
            let bitmap = GlyphBitmap(rows: ["▚"], cell: cell, scale: scale)
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<xm, y: 0..<ym), 1, accuracy: 0.001, "upper-left")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: xm..<w, y: ym..<h), 1, accuracy: 0.001, "lower-right")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: xm..<w, y: 0..<ym), 0, accuracy: 0.001, "upper-right")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<xm, y: ym..<h), 0, accuracy: 0.001, "lower-left")
            XCTAssertTrue(bitmap.padIsEmpty, "scale \(scale)")
        }
    }

    func testThreeQuadrantBlockFillsEveryQuadrantButUpperLeft() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale, xm = w / 2, ym = h / 2
            let bitmap = GlyphBitmap(rows: ["▟"], cell: cell, scale: scale)
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<xm, y: 0..<ym), 0, accuracy: 0.001, "upper-left")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: xm..<w, y: 0..<ym), 1, accuracy: 0.001, "upper-right")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<xm, y: ym..<h), 1, accuracy: 0.001, "lower-left")
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: xm..<w, y: ym..<h), 1, accuracy: 0.001, "lower-right")
        }
    }

    func testSingleQuadrantBlocksEachPaintExactlyOneQuadrant() {
        let cases: [(String, Int)] = [("▘", 0), ("▝", 1), ("▖", 2), ("▗", 3)]   // index: UL, UR, LL, LR
        for scale in scales {
            let w = 8 * scale, h = 16 * scale, xm = w / 2, ym = h / 2
            for (glyph, lit) in cases {
                let bitmap = GlyphBitmap(rows: [glyph], cell: cell, scale: scale)
                for index in 0..<4 {
                    let x = index % 2 == 0 ? 0..<xm : xm..<w
                    let y = index < 2 ? 0..<ym : ym..<h
                    XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: x, y: y), index == lit ? 1 : 0, accuracy: 0.001, "\(glyph) quadrant \(index) @\(scale)x")
                }
            }
        }
    }

    func testShadeBlocksCoverAQuarterHalfAndThreeQuarters() {
        let cases: [(String, Double)] = [("░", 0.25), ("▒", 0.5), ("▓", 0.75)]
        for scale in scales {
            let w = 8 * scale, h = 16 * scale
            for (glyph, expected) in cases {
                let bitmap = GlyphBitmap(rows: [glyph], cell: cell, scale: scale)
                XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<w, y: 0..<h), expected, accuracy: 0.03, "\(glyph) @\(scale)x")
                XCTAssertTrue(bitmap.padIsEmpty, "\(glyph) @\(scale)x")
            }
        }
    }

    func testStackedFullBlocksLeaveNoUnpaintedRowAtTheBoundary() {
        for scale in scales {
            let w = 8 * scale
            let bitmap = GlyphBitmap(rows: ["█", "█"], cell: cell, scale: scale)
            let boundary = bitmap.origin(row: 1, col: 0)
            for x in boundary.x..<(boundary.x + w) {
                XCTAssertEqual(bitmap.value(x: x, y: boundary.y - 1), 255, "last row of top █ @\(scale)x")
                XCTAssertEqual(bitmap.value(x: x, y: boundary.y), 255, "first row of bottom █ @\(scale)x")
            }
        }
    }

    func testLowerHalfAboveUpperHalfLeavesNoGapAtTheBoundary() {
        // A cell's bottom half (▄) and the next cell's top half (▀) share the row edge, so this pair is seamless.
        for scale in scales {
            let w = 8 * scale
            let bitmap = GlyphBitmap(rows: ["▄", "▀"], cell: cell, scale: scale)
            let boundary = bitmap.origin(row: 1, col: 0)
            for x in boundary.x..<(boundary.x + w) {
                XCTAssertEqual(bitmap.value(x: x, y: boundary.y - 1), 255, "▄ bottom @\(scale)x")
                XCTAssertEqual(bitmap.value(x: x, y: boundary.y), 255, "▀ top @\(scale)x")
            }
        }
    }

    func testFullBrailleCellLightsEightSeparateDots() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale
            let bitmap = GlyphBitmap(rows: ["⣿"], cell: cell, scale: scale)
            for row in 0..<4 {
                for col in 0..<2 {
                    XCTAssertGreaterThan(dotCoverage(bitmap, scale: scale, col: col, row: row), 0.2, "dot \(col),\(row) @\(scale)x")
                }
            }
            XCTAssertLessThan(bitmap.coverage(row: 0, col: 0, x: (w / 2)..<(w / 2 + 1), y: 0..<h), 0.01, "column gap @\(scale)x")
            for y in [h / 4, h / 2, 3 * h / 4] {
                XCTAssertLessThan(bitmap.coverage(row: 0, col: 0, x: 0..<w, y: y..<(y + 1)), 0.01, "row gap \(y) @\(scale)x")
            }
            XCTAssertTrue(bitmap.padIsEmpty, "scale \(scale)")
        }
    }

    func testSingleTopLeftDotBrailleGlyphLightsOnlyThatDot() {
        for scale in scales {
            let bitmap = GlyphBitmap(rows: ["⠁"], cell: cell, scale: scale)
            for row in 0..<4 {
                for col in 0..<2 {
                    let coverage = dotCoverage(bitmap, scale: scale, col: col, row: row)
                    if col == 0 && row == 0 { XCTAssertGreaterThan(coverage, 0.2, "dot 1 @\(scale)x") }
                    else { XCTAssertLessThan(coverage, 0.01, "dot \(col),\(row) @\(scale)x") }
                }
            }
            XCTAssertTrue(bitmap.padIsEmpty, "scale \(scale)")
        }
    }

    func testBlankBraillePaintsNothing() {
        for scale in scales {
            let w = 8 * scale, h = 16 * scale
            let bitmap = GlyphBitmap(rows: ["⠀"], cell: cell, scale: scale)
            XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<w, y: 0..<h), 0, accuracy: 0.0001, "scale \(scale)")
            XCTAssertTrue(bitmap.padIsEmpty, "scale \(scale)")
        }
    }

    func testLeftColumnBrailleGlyphLightsDotsOneTwoThreeSeven() {
        for scale in scales {
            let bitmap = GlyphBitmap(rows: ["⡇"], cell: cell, scale: scale)
            for row in 0..<4 {
                for col in 0..<2 {
                    let coverage = dotCoverage(bitmap, scale: scale, col: col, row: row)
                    if col == 0 { XCTAssertGreaterThan(coverage, 0.2, "\(col),\(row) @\(scale)x") }
                    else { XCTAssertLessThan(coverage, 0.01, "\(col),\(row) @\(scale)x") }
                }
            }
            XCTAssertTrue(bitmap.padIsEmpty, "scale \(scale)")
        }
    }

    /// Mean brightness of a 2×2 device-pixel box centred on the braille dot in `col`, `row`.
    private func dotCoverage(_ bitmap: GlyphBitmap, scale: Int, col: Int, row: Int) -> Double {
        let w = 8 * scale, h = 16 * scale
        let cx = (2 * col + 1) * w / 4, cy = (2 * row + 1) * h / 8
        return bitmap.coverage(row: 0, col: 0, x: (cx - 1)..<(cx + 1), y: (cy - 1)..<(cy + 1))
    }
}
