import CoreGraphics

/// U+2580–U+259F: half and eighth blocks, shades and quadrants. Shades use the fill colour at 25, 50 and 75% alpha.
enum BlockGlyphs {
    static func draw(_ code: UInt32, grid: GlyphGrid, context: CGContext) {
        guard (0x2580...0x259F).contains(code) else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setShouldAntialias(false)
        let w = grid.width, h = grid.height
        switch code {
        case 0x2580: fill(0, 0, w, h / 2, grid, context)                    // upper half
        case 0x2581...0x2588:                                               // lower 1/8…8/8
            // ▄ is the lower half: take the remainder so it meets ▀ at the same split.
            let piece = code == 0x2584 ? h - h / 2 : eighth(Int(code - 0x2580), of: h)
            fill(0, h - piece, w, h, grid, context)
        case 0x2589...0x258F:                                               // left 7/8…1/8
            // ▌ is the left half, matching ▐'s starting edge.
            let piece = code == 0x258C ? w / 2 : eighth(Int(0x2590 - code), of: w)
            fill(0, 0, piece, h, grid, context)
        case 0x2590: fill(w / 2, 0, w, h, grid, context)                    // right half
        case 0x2591...0x2593:                                               // ░▒▓
            shade(CGFloat(code - 0x2590) * 0.25, grid, context)
        case 0x2594: fill(0, 0, w, eighth(1, of: h), grid, context)         // upper 1/8
        case 0x2595: fill(w - eighth(1, of: w), 0, w, h, grid, context)     // right 1/8
        default:                                                           // quadrants U+2596–U+259F
            for (x0, y0, x1, y1) in quadrants(code, w: w, h: h) { fill(x0, y0, x1, y1, grid, context) }
        }
    }

    /// Rounded N/8 of a dimension, clamped to at least one pixel and to the dimension itself.
    private static func eighth(_ n: Int, of dimension: Int) -> Int { max(1, min(dimension, (n * dimension + 4) / 8)) }

    private static func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ grid: GlyphGrid, _ context: CGContext) {
        guard x1 > x0, y1 > y0 else { return }
        context.fill(grid.pixels(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }

    private static func shade(_ alpha: CGFloat, _ grid: GlyphGrid, _ context: CGContext) {
        context.setAlpha(alpha)   // scales the fill colour CellGlyphs already installed
        context.fill(grid.pixels(x: 0, y: 0, width: grid.width, height: grid.height))
    }

    /// Pixel boxes (x0, y0, x1, y1) for the quadrants set in U+2596–U+259F. Splits follow the same
    /// `dimension / 2` rule as the half blocks so complementary quadrants tile exactly.
    private static func quadrants(_ code: UInt32, w: Int, h: Int) -> [(Int, Int, Int, Int)] {
        let mask: UInt32
        switch code {
        case 0x2596: mask = 0b0100                    // lower-left
        case 0x2597: mask = 0b1000                    // lower-right
        case 0x2598: mask = 0b0001                    // upper-left
        case 0x2599: mask = 0b1101                    // upper-left, lower-left, lower-right
        case 0x259A: mask = 0b1001                    // upper-left, lower-right
        case 0x259B: mask = 0b0111                    // upper-left, upper-right, lower-left
        case 0x259C: mask = 0b1011                    // upper-left, upper-right, lower-right
        case 0x259D: mask = 0b0010                    // upper-right
        case 0x259E: mask = 0b0110                    // upper-right, lower-left
        default: mask = 0b1110                        // 0x259F: upper-right, lower-left, lower-right
        }
        let xm = w / 2, ym = h / 2
        var boxes: [(Int, Int, Int, Int)] = []
        if mask & 0b0001 != 0 { boxes.append((0, 0, xm, ym)) }
        if mask & 0b0010 != 0 { boxes.append((xm, 0, w, ym)) }
        if mask & 0b0100 != 0 { boxes.append((0, ym, xm, h)) }
        if mask & 0b1000 != 0 { boxes.append((xm, ym, w, h)) }
        return boxes
    }
}

/// U+2800–U+28FF: the 2×4 braille dot grid.
enum BrailleGlyphs {
    /// Bit index → (column, row): dots 1–3 run down the left column, 4–6 the right, 7–8 the bottom.
    private static let dots: [(Int, Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]

    static func draw(_ code: UInt32, grid: GlyphGrid, context: CGContext) {
        guard (0x2800...0x28FF).contains(code) else { return }
        let bits = code - 0x2800
        guard bits != 0 else { return }                     // U+2800 is blank
        context.saveGState(); defer { context.restoreGState() }
        context.setShouldAntialias(true)
        let w = CGFloat(grid.width), h = CGFloat(grid.height)
        let radius = max(1, 0.8 * min(w / 4, h / 8)) / 2 / grid.scale
        for (bit, dot) in dots.enumerated() where bits & (1 << bit) != 0 {
            let centre = grid.point(x: (CGFloat(2 * dot.0 + 1) / 4) * w, y: (CGFloat(2 * dot.1 + 1) / 8) * h)
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        }
    }
}
