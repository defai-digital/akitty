import AppKit
import XCTest
@testable import AkittyKit

final class FontMetricsTests: XCTestCase {
    @MainActor func testFontChangesKeepGridMetricsCompatibleAndInvalidateCachedValues() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        for name in ["System Monospaced", "Menlo", "Courier"] {
            for size in [9.0, 14.0, 24.0, 36.0] {
                var preferences = TerminalPreferences(); preferences.fontName = name; preferences.fontSize = size
                terminal.applyPreferences(preferences)
                let font = name == "System Monospaced" ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : try XCTUnwrap(NSFont(name: name, size: size))
                // One reference measurement per setting preserves the established grid geometry.
                let expected = CGSize(width: ceil(("M" as NSString).size(withAttributes: [.font: font]).width),
                                      height: ceil(font.ascender - font.descender + font.leading + 4))
                XCTAssertEqual(terminal.cellSize, expected, "\(name) at \(size)")
                terminal.changeFont(-1)
                if size > 9 { XCTAssertLessThanOrEqual(terminal.cellSize.height, expected.height) }
                terminal.changeFont(nil)
                XCTAssertEqual(terminal.cellSize, expected)
            }
        }
    }

    @MainActor func testMissingFontAndInvalidPointSizesStillHaveBoundedGridMetrics() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        for size in [Double.nan, Double.infinity, -1, 1e100] {
            var preferences = TerminalPreferences(); preferences.fontName = "akitty-missing-font"; preferences.fontSize = size
            terminal.applyPreferences(preferences)
            XCTAssertTrue((1...256).contains(terminal.cellSize.width))
            XCTAssertTrue((1...512).contains(terminal.cellSize.height))
        }
    }

    @MainActor func testRepeatedCellMeasurementsWhileBackgroundRasterizersShapeText() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        _ = try terminal.session.call("feed", ["text": "ASCII 中 日本語 한글 👩🏽‍💻"])
        let snapshot = try XCTUnwrap(terminal.session.snapshot())
        let fontName = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontName
        let expected = terminal.cellSize
        let completed = expectation(description: "independent rasterizers complete")
        completed.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            DispatchQueue.global(qos: .userInitiated).async {
                defer { completed.fulfill() }
                let rasterizer = GridRasterizer()
                for iteration in 0..<100 {
                    autoreleasepool {
                        do {
                            _ = try rasterizer.render(snapshot: snapshot, damage: nil, size: CGSize(width: 900, height: 600), scale: 1,
                                                      fontName: fontName, fontSize: CGFloat(14 + iteration % 3), cellSize: expected, composition: "かな\(iteration)")
                        } catch { XCTFail("Background rendering failed: \(error)") }
                    }
                }
            }
        }
        for _ in 0..<20_000 { XCTAssertEqual(terminal.cellSize, expected) }
        await fulfillment(of: [completed], timeout: 20)
    }
}
