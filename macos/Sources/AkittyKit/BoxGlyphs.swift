import CoreGraphics

/// U+2500–U+257F: lines, corners, tees and crosses in light, heavy and double weights, dashes, arcs and diagonals.
enum BoxGlyphs {
    /// One arm of a line character. The table names a weight per direction; the geometry turns those weights into
    /// pixel-aligned rectangles. `double` is two light strokes separated by a gap of one light stroke.
    private enum Arm: UInt8 { case none, light, heavy, double }

    private struct Arms {
        let up: Arm, down: Arm, left: Arm, right: Arm
        init(_ up: Arm = .none, _ down: Arm = .none, _ left: Arm = .none, _ right: Arm = .none) {
            (self.up, self.down, self.left, self.right) = (up, down, left, right)
        }
    }

    static func draw(_ code: UInt32, grid: GlyphGrid, context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        switch code {
        case 0x2504...0x250B, 0x254C...0x254F: dashes(code, grid, context)
        case 0x256D...0x2570: rounded(code, grid, context)
        case 0x2571...0x2573: diagonals(code, grid, context)
        default:
            guard let arms = armSet(for: code) else { return }
            strokes(arms, grid, context)
        }
    }

    /// Arm weights per code point. Dashes, arcs and diagonals are shapes rather than arm combinations.
    private static func armSet(for code: UInt32) -> Arms? {
        switch code {
        case 0x2500...0x254B: table[Int(code - 0x2500)]
        case 0x2550...0x256C: doubles[Int(code - 0x2550)]
        case 0x2574...0x257F: halves[Int(code - 0x2574)]
        default: nil
        }
    }

    private static func fill(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ grid: GlyphGrid, _ context: CGContext) {
        guard width > 0, height > 0 else { return }
        context.fill(grid.pixels(x: x, y: y, width: width, height: height))
    }

    /// Pixel-aligned strokes for the arm table. Light and heavy arms are one centred band each; a double arm is two
    /// light walls around a light gap. A one-sided double arm reaches across the whole crossing band so the join has no
    /// hole; both sides together span the cell.
    private static func strokes(_ arms: Arms, _ grid: GlyphGrid, _ context: CGContext) {
        context.setShouldAntialias(false)
        if let corner = doubleCorner(arms, grid) {
            for (x, y, width, height) in corner { fill(x, y, width, height, grid, context) }
            return
        }
        let w = grid.width, h = grid.height, l = grid.light
        let xl = (w - l) / 2, yl = (h - l) / 2                 // light bands, centred
        let xh = (w - 2 * l) / 2, yh = (h - 2 * l) / 2         // heavy bands, centred
        let xd = (w - 3 * l) / 2, yd = (h - 3 * l) / 2         // outer edge of a double band
        // A crossing line's full band: a one-sided double arm reaches over it to the far edge.
        let horizontal = arms.left != .none || arms.right != .none
        let vertical = arms.up != .none || arms.down != .none
        let top = horizontal ? min(bandTop(arms.left, l, yh, yl, yd, h), bandTop(arms.right, l, yh, yl, yd, h)) : 0
        let bottom = horizontal ? max(bandBottom(arms.left, l, yh, yl, yd), bandBottom(arms.right, l, yh, yl, yd)) : h
        let left = vertical ? min(bandTop(arms.up, l, xh, xl, xd, w), bandTop(arms.down, l, xh, xl, xd, w)) : 0
        let right = vertical ? max(bandBottom(arms.up, l, xh, xl, xd), bandBottom(arms.down, l, xh, xl, xd)) : w

        switch arms.up {
        case .none: break
        case .light: fill(xl, 0, l, yl + l, grid, context)
        case .heavy: fill(xh, 0, 2 * l, yh + 2 * l, grid, context)
        case .double:
            let end = arms.down == .double ? h : bottom
            for x in [xd, xd + 2 * l] { fill(x, 0, l, end, grid, context) }
        }
        switch arms.down {
        case .none: break
        case .light: fill(xl, yl, l, h - yl, grid, context)
        case .heavy: fill(xh, yh, 2 * l, h - yh, grid, context)
        case .double:
            let start = arms.up == .double ? 0 : top
            for x in [xd, xd + 2 * l] { fill(x, start, l, h - start, grid, context) }
        }
        switch arms.left {
        case .none: break
        case .light: fill(0, yl, xl + l, l, grid, context)
        case .heavy: fill(0, yh, xh + 2 * l, 2 * l, grid, context)
        case .double:
            let end = arms.right == .double ? w : right
            for y in [yd, yd + 2 * l] { fill(0, y, end, l, grid, context) }
        }
        switch arms.right {
        case .none: break
        case .light: fill(xl, yl, w - xl, l, grid, context)
        case .heavy: fill(xh, yh, w - xh, 2 * l, grid, context)
        case .double:
            let start = arms.left == .double ? 0 : left
            for y in [yd, yd + 2 * l] { fill(start, y, w - start, l, grid, context) }
        }
    }

    /// Top edge of a crossing arm's band; absent arms fall outside the cell so `min`/`max` ignore them.
    private static func bandTop(_ arm: Arm, _ l: Int, _ heavy: Int, _ light: Int, _ double: Int, _ empty: Int) -> Int {
        switch arm { case .heavy: heavy; case .light: light; case .double: double; case .none: empty }
    }
    /// Bottom edge of a crossing arm's band.
    private static func bandBottom(_ arm: Arm, _ l: Int, _ heavy: Int, _ light: Int, _ double: Int) -> Int {
        switch arm { case .heavy: heavy + 2 * l; case .light: light + l; case .double: double + 3 * l; case .none: -1 }
    }

    /// A corner of two double arms turns the outer walls around the outside and the inner walls inside, so each wall
    /// stops where its partner starts and the hollow turns the corner instead of being crossed.
    private static func doubleCorner(_ arms: Arms, _ grid: GlyphGrid) -> [(Int, Int, Int, Int)]? {
        let up = arms.up == .double, down = arms.down == .double
        let left = arms.left == .double, right = arms.right == .double
        guard up != down, left != right else { return nil }
        guard [arms.up, arms.down, arms.left, arms.right].allSatisfy({ $0 == .none || $0 == .double }) else { return nil }
        let l = grid.light, w = grid.width, h = grid.height
        let x = (w - 3 * l) / 2, y = (h - 3 * l) / 2
        // The outer corner is opposite both arms; the inner corner is inset by one wall and one gap.
        let outerV = right ? x : x + 2 * l, innerV = right ? x + 2 * l : x
        let outerH = down ? y : y + 2 * l, innerH = down ? y + 2 * l : y
        let outerVStart = down ? y : 0, outerVEnd = down ? h : y + 3 * l
        let innerVStart = down ? y + 2 * l : 0, innerVEnd = down ? h : y + l
        let outerHStart = right ? x : 0, outerHEnd = right ? w : x + 3 * l
        let innerHStart = right ? x + 2 * l : 0, innerHEnd = right ? w : x + l
        return [(outerV, outerVStart, l, outerVEnd - outerVStart), (outerHStart, outerH, outerHEnd - outerHStart, l),
                (innerV, innerVStart, l, innerVEnd - innerVStart), (innerHStart, innerH, innerHEnd - innerHStart, l)]
    }

    /// Dashed lines: each period is a dash with half a gap at each end, so the gap between cells is as wide as the
    /// gaps inside them and the rhythm continues across the row; everything snaps to whole pixels.
    private static func dashes(_ code: UInt32, _ grid: GlyphGrid, _ context: CGContext) {
        let count: Int, vertical: Bool, heavy: Bool
        switch code {
        case 0x2504...0x250B:
            let index = Int(code - 0x2504)
            (count, vertical, heavy) = (index < 4 ? 3 : 4, index % 4 >= 2, index % 2 == 1)
        default:
            let index = Int(code - 0x254C)
            (count, vertical, heavy) = (2, index >= 2, index % 2 == 1)
        }
        context.setShouldAntialias(false)
        let t = heavy ? grid.heavy : grid.light
        let along = vertical ? grid.height : grid.width
        let period = Double(along) / Double(count)
        let halfGap = Double(max(1, Int((period / 3).rounded()))) / 2
        for index in 0..<count {
            // Half a gap inside each end of every period, so joins between cells fall on gaps, not dashes.
            let start = Int((Double(index) * period + halfGap).rounded())
            let end = min(along, Int((Double(index + 1) * period - halfGap).rounded(.down)))
            guard end > start else { continue }
            if vertical { fill((grid.width - t) / 2, start, t, end - start, grid, context) }
            else { fill(start, (grid.height - t) / 2, end - start, t, grid, context) }
        }
    }

    /// ╭ ╮ ╯ ╰: a quarter-circle arc tangent to the two centre lines, with straight stubs out to the connected edges.
    private static func rounded(_ code: UInt32, _ grid: GlyphGrid, _ context: CGContext) {
        let down = code == 0x256D || code == 0x256E
        let right = code == 0x256D || code == 0x2570
        let w = CGFloat(grid.width), h = CGFloat(grid.height)
        // Stroke centre lines of the plain arms, so the stubs line up with ─ and │ in the neighbouring cells.
        let axisX = CGFloat((grid.width - grid.light) / 2) + CGFloat(grid.light) / 2
        let axisY = CGFloat((grid.height - grid.light) / 2) + CGFloat(grid.light) / 2
        // A small turn: the arc stays near the cell centre and every edge keeps a full pixel of straight stub.
        let radius = max(0.5, min(2.5, axisX - 0.5, axisY - 0.5))
        let centreX = axisX + (right ? radius : -radius), centreY = axisY + (down ? radius : -radius)
        let startX = axisX, startY = axisY + (down ? radius : -radius)
        let endX = axisX + (right ? radius : -radius), endY = axisY
        let start = atan2(startY - centreY, startX - centreX)
        var sweep = atan2(endY - centreY, endX - centreX) - start
        while sweep > .pi / 2 { sweep -= 2 * .pi }
        while sweep < -.pi / 2 { sweep += 2 * .pi }
        let path = CGMutablePath()
        path.move(to: grid.point(x: axisX, y: down ? h : 0))
        path.addLine(to: grid.point(x: startX, y: startY))
        let steps = 24
        for step in 0...steps {
            let angle = start + sweep * CGFloat(step) / CGFloat(steps)
            path.addLine(to: grid.point(x: centreX + radius * cos(angle), y: centreY + radius * sin(angle)))
        }
        path.addLine(to: grid.point(x: right ? w : 0, y: axisY))
        context.setShouldAntialias(true)
        context.setLineWidth(CGFloat(grid.light) / grid.scale)
        context.setLineCap(.butt)
        context.addPath(path)
        context.strokePath()
    }

    /// ╱ ╲ ╳: anti-aliased light strokes between opposite corners, extended by half a stroke so the corners fill.
    private static func diagonals(_ code: UInt32, _ grid: GlyphGrid, _ context: CGContext) {
        context.setShouldAntialias(true)
        context.setLineWidth(CGFloat(grid.light) / grid.scale)
        context.setLineCap(.butt)
        let w = CGFloat(grid.width), h = CGFloat(grid.height), over = CGFloat(grid.light) / 2
        let path = CGMutablePath()
        func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            path.move(to: grid.point(x: x0, y: y0)); path.addLine(to: grid.point(x: x1, y: y1))
        }
        if code != 0x2572 { line(-over, h + over, w + over, -over) }   // ╱ upper right to lower left
        if code != 0x2571 { line(-over, -over, w + over, h + over) }   // ╲ upper left to lower right
        context.addPath(path)
        context.strokePath()
    }

    /// U+2500–U+254B, four per line; U+2504–U+250B are dashes and only keep their slots so indices stay aligned.
    private static let table: [Arms] = [
        a(.none, .none, .light, .light), a(.none, .none, .heavy, .heavy), a(.light, .light, .none, .none), a(.heavy, .heavy, .none, .none), // ─ ━ │ ┃
        a(), a(), a(), a(),                                                                                                             // ┄ ┅ ┆ ┇
        a(), a(), a(), a(),                                                                                                             // ┈ ┉ ┊ ┋
        a(.none, .light, .none, .light), a(.none, .light, .none, .heavy), a(.none, .heavy, .none, .light), a(.none, .heavy, .none, .heavy), // ┌ ┍ ┎ ┏
        a(.none, .light, .light, .none), a(.none, .light, .heavy, .none), a(.none, .heavy, .light, .none), a(.none, .heavy, .heavy, .none), // ┐ ┑ ┒ ┓
        a(.light, .none, .none, .light), a(.light, .none, .none, .heavy), a(.heavy, .none, .none, .light), a(.heavy, .none, .none, .heavy), // └ ┕ ┖ ┗
        a(.light, .none, .light, .none), a(.light, .none, .heavy, .none), a(.heavy, .none, .light, .none), a(.heavy, .none, .heavy, .none), // ┘ ┙ ┚ ┛
        a(.light, .light, .none, .light), a(.light, .light, .none, .heavy), a(.heavy, .light, .none, .light), a(.light, .heavy, .none, .light), // ├ ┝ ┞ ┟
        a(.heavy, .heavy, .none, .light), a(.heavy, .light, .none, .heavy), a(.light, .heavy, .none, .heavy), a(.heavy, .heavy, .none, .heavy), // ┠ ┡ ┢ ┣
        a(.light, .light, .light, .none), a(.light, .light, .heavy, .none), a(.heavy, .light, .light, .none), a(.light, .heavy, .light, .none), // ┤ ┥ ┦ ┧
        a(.heavy, .heavy, .light, .none), a(.heavy, .light, .heavy, .none), a(.light, .heavy, .heavy, .none), a(.heavy, .heavy, .heavy, .none), // ┨ ┩ ┪ ┫
        a(.none, .light, .light, .light), a(.none, .light, .heavy, .light), a(.none, .light, .light, .heavy), a(.none, .light, .heavy, .heavy), // ┬ ┭ ┮ ┯
        a(.none, .heavy, .light, .light), a(.none, .heavy, .heavy, .light), a(.none, .heavy, .light, .heavy), a(.none, .heavy, .heavy, .heavy), // ┰ ┱ ┲ ┳
        a(.light, .none, .light, .light), a(.light, .none, .heavy, .light), a(.light, .none, .light, .heavy), a(.light, .none, .heavy, .heavy), // ┴ ┵ ┶ ┷
        a(.heavy, .none, .light, .light), a(.heavy, .none, .heavy, .light), a(.heavy, .none, .light, .heavy), a(.heavy, .none, .heavy, .heavy), // ┸ ┹ ┺ ┻
        a(.light, .light, .light, .light), a(.light, .light, .heavy, .light), a(.light, .light, .light, .heavy), a(.light, .light, .heavy, .heavy), // ┼ ┽ ┾ ┿
        a(.heavy, .light, .light, .light), a(.light, .heavy, .light, .light), a(.heavy, .heavy, .light, .light), a(.heavy, .light, .heavy, .light), // ╀ ╁ ╂ ╃
        a(.heavy, .light, .light, .heavy), a(.light, .heavy, .heavy, .light), a(.light, .heavy, .light, .heavy), a(.heavy, .light, .heavy, .heavy), // ╄ ╅ ╆ ╇
        a(.light, .heavy, .heavy, .heavy), a(.heavy, .heavy, .heavy, .light), a(.heavy, .heavy, .light, .heavy), a(.heavy, .heavy, .heavy, .heavy), // ╈ ╉ ╊ ╋
    ]

    /// U+2550–U+256C. An unqualified direction in a Unicode name is light; "DOUBLE X AND Y" makes both directions double.
    private static let doubles: [Arms] = [
        a(.none, .none, .double, .double), a(.double, .double, .none, .none), a(.none, .light, .none, .double), a(.none, .double, .none, .light), // ═ ║ ╒ ╓
        a(.none, .double, .none, .double), a(.none, .light, .double, .none), a(.none, .double, .light, .none), a(.none, .double, .double, .none), // ╔ ╕ ╖ ╗
        a(.light, .none, .none, .double), a(.double, .none, .none, .light), a(.double, .none, .none, .double), a(.light, .none, .double, .none), // ╘ ╙ ╚ ╛
        a(.double, .none, .light, .none), a(.double, .none, .double, .none), a(.light, .light, .none, .double), a(.double, .double, .none, .light), // ╜ ╝ ╞ ╟
        a(.double, .double, .none, .double), a(.light, .light, .double, .none), a(.double, .double, .light, .none), a(.double, .double, .double, .none), // ╠ ╡ ╢ ╣
        a(.none, .light, .double, .double), a(.none, .double, .light, .light), a(.none, .double, .double, .double), a(.light, .none, .double, .double), // ╤ ╥ ╦ ╧
        a(.double, .none, .light, .light), a(.double, .none, .double, .double), a(.light, .light, .double, .double), a(.double, .double, .light, .light), // ╨ ╩ ╪ ╫
        a(.double, .double, .double, .double),                                                                                        // ╬
    ]

    /// U+2574–U+257F: half lines and the mixed light/heavy halves, each a single arm from the junction to one edge.
    private static let halves: [Arms] = [
        a(.none, .none, .light, .none), a(.light, .none, .none, .none), a(.none, .none, .none, .light), a(.none, .light, .none, .none), // ╴ ╵ ╶ ╷
        a(.none, .none, .heavy, .none), a(.heavy, .none, .none, .none), a(.none, .none, .none, .heavy), a(.none, .heavy, .none, .none), // ╸ ╹ ╺ ╻
        a(.none, .none, .light, .heavy), a(.light, .heavy, .none, .none), a(.none, .none, .heavy, .light), a(.heavy, .light, .none, .none), // ╼ ╽ ╾ ╿
    ]

    private static func a(_ up: Arm = .none, _ down: Arm = .none, _ left: Arm = .none, _ right: Arm = .none) -> Arms {
        Arms(up, down, left, right)
    }
}
