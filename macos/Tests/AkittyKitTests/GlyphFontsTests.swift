import XCTest
import AppKit
import CoreText
@testable import AkittyKit

final class GlyphFontsTests: XCTestCase {
    private let allCJKFonts = ["PingFang SC", "PingFang TC", "PingFang HK", "Hiragino Sans", "Apple SD Gothic Neo"]

    func testJapaneseLanguagePrefersHiraginoSans() {
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: ["ja-JP"]).first, "Hiragino Sans")
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: ["en-US", "ja"]).first, "Hiragino Sans")
    }

    func testKoreanLanguagePrefersAppleSDGothicNeo() {
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: ["ko-KR"]).first, "Apple SD Gothic Neo")
    }

    func testTraditionalChineseTaiwanPrefersPingFangTC() {
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: ["zh-Hant-TW"]).first, "PingFang TC")
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: ["zh-TW"]).first, "PingFang TC")
    }

    func testHongKongPrefersPingFangHKOverPingFangTC() {
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: ["zh-HK"]).first, "PingFang HK")
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: ["zh-Hant-HK"]).first, "PingFang HK")
    }

    func testSimplifiedChineseAndUnrelatedLanguagesDefaultToPingFangSCFirst() {
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: ["zh-Hans-CN"]).first, "PingFang SC")
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: ["en-US"]).first, "PingFang SC")
        XCTAssertEqual(GlyphFonts.preferredCJKFontNames(languages: []).first, "PingFang SC")
    }

    func testEveryLanguageListKeepsAllFiveFontsWithoutDuplicates() {
        for languages in [["ja"], ["ko"], ["zh-Hant"], ["zh-HK"], ["en-US"], [], ["fr-FR", "de-DE"]] {
            let names = GlyphFonts.preferredCJKFontNames(languages: languages)
            XCTAssertEqual(names.count, allCJKFonts.count, "no duplicates for \(languages)")
            XCTAssertEqual(Set(names), Set(allCJKFonts), "every CJK script keeps a face for \(languages)")
        }
    }

    func testInstalledAcceptsMenloAndRejectsUnknownNames() {
        XCTAssertTrue(GlyphFonts.installed("Menlo"))
        XCTAssertFalse(GlyphFonts.installed("No Such Font 12345"))
        XCTAssertFalse(GlyphFonts.installed(""), "the automatic sentinel is not a font name")
    }

    func testCascadeFontKeepsTheBaseSizeAndLeadsWithTheLanguageFace() throws {
        try XCTSkipUnless(GlyphFonts.installed("Hiragino Sans"), "Hiragino Sans is not installed")
        let font = GlyphFonts.cascadeFont(base: menlo(size: 14), cjkFontName: "", languages: ["ja"])
        XCTAssertEqual(CTFontGetSize(font), 14, accuracy: 1e-9)
        XCTAssertEqual(cascadeFamilies(of: font).first, "Hiragino Sans")
    }

    func testCascadeFontPutsAnExplicitInstalledChoiceAheadOfTheLanguageDefault() throws {
        try XCTSkipUnless(GlyphFonts.installed("PingFang TC"), "PingFang TC is not installed")
        let font = GlyphFonts.cascadeFont(base: menlo(size: 12), cjkFontName: "PingFang TC", languages: ["ja"])
        XCTAssertEqual(cascadeFamilies(of: font).first, "PingFang TC")
    }

    func testCascadeFontIgnoresAGarbageNameAndStillRendersNonASCII() {
        let font = GlyphFonts.cascadeFont(base: menlo(size: 13), cjkFontName: "No Such Font 12345", languages: ["ko"])
        XCTAssertEqual(CTFontGetSize(font), 13, accuracy: 1e-9)
        XCTAssertFalse(cascadeFamilies(of: font).contains("No Such Font 12345"))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "한", attributes: [.font: font]))
        XCTAssertFalse(CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).isEmpty)
    }

    func testNarrowGlyphThatFitsKeepsItsOriginAndScaleOne() {
        let box = CGRect(x: 100, y: 200, width: 10, height: 20)
        let ink = CGRect(x: 1, y: 0, width: 7, height: 12)
        let (origin, scale) = GlyphFonts.placement(ink: ink, box: box, baseline: 204, centre: false)
        XCTAssertEqual(scale, 1, accuracy: 1e-9)
        XCTAssertEqual(origin.x, box.minX, accuracy: 1e-9, "a glyph that fits keeps the font's own left bearing")
        XCTAssertEqual(origin.y, 204, accuracy: 1e-9)
    }

    func testInkWiderThanTheBoxIsScaledDownAndFits() {
        let box = CGRect(x: 0, y: 0, width: 20, height: 20)
        let ink = CGRect(x: 0, y: 0, width: 30, height: 12)
        for centre in [true, false] {
            let (origin, scale) = GlyphFonts.placement(ink: ink, box: box, baseline: 3, centre: centre)
            XCTAssertLessThan(scale, 1, "wider ink is shrunk")
            XCTAssertLessThanOrEqual(scale * ink.width, box.width + 1e-6, "scaled ink fits the width")
            XCTAssertEqual(origin.x + scale * ink.minX, box.minX, accuracy: 1e-6)
        }
    }

    func testTallInkIsShiftedAndScaledToStayInsideTheBox() {
        let box = CGRect(x: 0, y: 200, width: 10, height: 20)
        let ink = CGRect(x: 0, y: -5, width: 8, height: 40)
        let (origin, scale) = GlyphFonts.placement(ink: ink, box: box, baseline: 203, centre: false)
        XCTAssertLessThan(scale, 1, "taller ink is shrunk")
        XCTAssertGreaterThanOrEqual(origin.y + scale * ink.minY, box.minY - 1e-6)
        XCTAssertLessThanOrEqual(origin.y + scale * ink.maxY, box.maxY + 1e-6)
        XCTAssertNotEqual(origin.y, 203, "the baseline alone would draw outside the row")
    }

    func testCentreTruePutsTheInkMidpointOnTheBoxMidpoint() {
        let box = CGRect(x: 100, y: 0, width: 20, height: 20)
        let ink = CGRect(x: 1, y: 2, width: 10, height: 8)
        let (origin, scale) = GlyphFonts.placement(ink: ink, box: box, baseline: 3, centre: true)
        XCTAssertEqual(scale, 1, accuracy: 1e-9)
        XCTAssertEqual(origin.x + ink.midX, box.midX, accuracy: 1e-9)
    }

    private func menlo(size: CGFloat) -> CTFont { CTFontCreateWithName("Menlo" as CFString, size, nil) }

    private func cascadeFamilies(of font: CTFont) -> [String] {
        let list = CTFontCopyAttribute(font, kCTFontCascadeListAttribute) as? [CTFontDescriptor] ?? []
        return list.map { CTFontCopyFamilyName(CTFontCreateWithFontDescriptor($0, CTFontGetSize(font), nil)) as String }
    }
}
