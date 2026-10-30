import CoreText
import Foundation

/// Pure helpers for the rasterizer: which CJK faces to fall back to, and where a
/// non-ASCII glyph goes inside its cell box. No drawing happens here.
enum GlyphFonts {
    /// Fallback order after the language-preferred face, so every CJK script still has one.
    static let cjkOrder = ["PingFang SC", "PingFang TC", "PingFang HK", "Hiragino Sans", "Apple SD Gothic Neo"]

    /// Font names in preference order for the user's ordered language tags (`Locale.preferredLanguages`).
    /// The first language that maps to a CJK script wins; the rest keep the canonical SC, TC, HK, JA, KO order.
    static func preferredCJKFontNames(languages: [String]) -> [String] {
        let first = languages.compactMap { font(forLanguage: $0) }.first
        return cjkOrder.filter { $0 == first } + cjkOrder.filter { $0 != first }
    }

    /// A language tag maps to a face by script, not by exact tag: `zh-HK` needs HK, `zh-Hant-TW` needs TC.
    private static func font(forLanguage tag: String) -> String? {
        let tag = tag.lowercased()
        if tag == "ja" || tag.hasPrefix("ja-") { return "Hiragino Sans" }
        if tag == "ko" || tag.hasPrefix("ko-") { return "Apple SD Gothic Neo" }
        guard tag == "zh" || tag.hasPrefix("zh-") else { return nil }
        if tag.contains("-hk") { return "PingFang HK" }
        if tag.contains("-hant") || tag.contains("-tw") || tag.contains("-mo") { return "PingFang TC" }
        return "PingFang SC"
    }

    /// CoreText silently substitutes the system font for unknown names, so the request has to be
    /// compared with what was actually resolved. Spaces are ignored so `PingFangSC-Regular` still counts.
    static func installed(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let resolved = [CTFontCopyFamilyName(font), CTFontCopyFullName(font), CTFontCopyPostScriptName(font)]
        let squash = { (value: String) in value.lowercased().replacingOccurrences(of: " ", with: "") }
        return resolved.map { squash($0 as String) }.contains(squash(name))
    }

    /// `base` with a CJK-first cascade list, same size and traits. The rasterizer caches one font per
    /// weight/style, so the cascade is what makes every script on a row use the intended regional face.
    static func cascadeFont(base: CTFont, cjkFontName: String, languages: [String]) -> CTFont {
        let size = CTFontGetSize(base)
        var names: [String] = []
        if !cjkFontName.isEmpty, installed(cjkFontName) { names.append(cjkFontName) }
        names += preferredCJKFontNames(languages: languages).filter(installed)
        var seen = Set<String>()
        let cjk = names.filter { seen.insert($0).inserted }.map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, size) }
        // Keep the system cascade behind the CJK faces so symbols, emoji and any script the chosen
        // faces lack still resolve exactly as they do for the base font alone.
        let system = CTFontCopyDefaultCascadeListForLanguages(base, languages.isEmpty ? nil : (languages as CFArray))
        let attributes = [kCTFontCascadeListAttribute: cjk + ((system as? [CTFontDescriptor]) ?? [])] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), attributes)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Where to put a glyph line so its ink stays inside `box`, and how much to shrink it.
    ///
    /// `ink` is `CTLineGetBoundsWithOptions(_: .useGlyphPathBounds)`, i.e. glyph-path bounds relative to
    /// the text origin. The caller applies `scale` **about the returned origin** (translate to `origin`,
    /// scale, then draw at a zero text position), so the ink lands on `origin + scale * ink`. `scale` is
    /// never above 1. `centre == true` (wide cells) centres the ink in the box; `centre == false`
    /// (narrow cells) only corrects overflow, so a glyph that already fits keeps its origin on
    /// `box.minX` and the caller's baseline, and one that must shrink is centred.
    static func placement(ink: CGRect, box: CGRect, baseline: CGFloat, centre: Bool) -> (origin: CGPoint, scale: CGFloat) {
        let ink = ink.standardized
        var scale: CGFloat = 1
        if ink.width > 0, box.width > 0 { scale = min(scale, box.width / ink.width) }
        if ink.height > 0, box.height > 0 { scale = min(scale, box.height / ink.height) }
        guard scale.isFinite, scale > 0 else { return (CGPoint(x: box.minX, y: baseline), 1) }
        // A narrow glyph that fits keeps the font's own left bearing (origin on the cell edge); one that had to shrink is centred.
        let x = centre || scale < 1 ? box.midX - scale * ink.midX : box.minX
        // Shift to whichever edge the ink would cross; once it fits, the baseline is left alone.
        var y = baseline
        if y + scale * ink.minY < box.minY { y = box.minY - scale * ink.minY }
        else if y + scale * ink.maxY > box.maxY { y = box.maxY - scale * ink.maxY }
        return (CGPoint(x: x, y: y), scale)
    }
}
