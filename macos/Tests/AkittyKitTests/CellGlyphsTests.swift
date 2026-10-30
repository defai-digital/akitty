import XCTest
@testable import AkittyKit

final class CellGlyphsTests: XCTestCase {
    func testGlyphBitmapHelperPaintsNothingForUnhandledAndSpace() {
        let bitmap = GlyphBitmap(rows: [" "])
        XCTAssertEqual(bitmap.coverage(row: 0, col: 0, x: 0..<8, y: 0..<16), 0)
        XCTAssertTrue(bitmap.padIsEmpty)
    }
    func testHandlesOnlyBoxBlockAndBrailleRanges() {
        for code: UInt32 in [0x2500, 0x257F, 0x2580, 0x259F, 0x2800, 0x28FF] { XCTAssertTrue(CellGlyphs.handles(Unicode.Scalar(code)!), String(code, radix: 16)) }
        for code: UInt32 in [0x24FF, 0x25A0, 0x27FF, 0x2900, 0x41, 0x4E2D] { XCTAssertFalse(CellGlyphs.handles(Unicode.Scalar(code)!), String(code, radix: 16)) }
    }
    func testGridStrokeThicknessScalesWithTheDisplay() {
        XCTAssertEqual(GlyphGrid(rect: CGRect(x: 0, y: 0, width: 8, height: 16), scale: 1).light, 1)
        XCTAssertEqual(GlyphGrid(rect: CGRect(x: 0, y: 0, width: 8, height: 16), scale: 2).light, 2)
        XCTAssertEqual(GlyphGrid(rect: CGRect(x: 0, y: 0, width: 8, height: 16), scale: 2).heavy, 4)
    }
    func testGeometricGlyphsSurviveTinyAndOddCellSizesWithoutLeavingTheCell() {
        let ranges: [ClosedRange<UInt32>] = [0x2500...0x259F, 0x2800...0x28FF]
        for (w, h) in [(1, 1), (2, 3), (3, 5), (5, 7), (7, 13), (9, 19)] {
            for scale in [1, 2, 3] {
                for range in ranges { for code in range {
                    guard let scalar = Unicode.Scalar(code) else { continue }
                    let bitmap = GlyphBitmap(rows: [String(scalar), String(scalar)], cell: CGSize(width: w, height: h), scale: scale)
                    XCTAssertTrue(bitmap.padIsEmpty, "U+\(String(code, radix: 16)) in \(w)x\(h) @\(scale)x")
                } }
            }
        }
    }
}
