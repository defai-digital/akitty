import CoreGraphics
import Foundation

/// Characters drawn from geometry instead of the font. Rows are taller than font glyphs, so a font's `│` or `█` leaves
/// gaps between rows; drawing them to the exact cell box makes strokes and fills meet across neighbouring cells.
enum CellGlyphs {
    static func handles(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value { case 0x2500...0x259F, 0x2800...0x28FF: true; default: false }
    }
    /// Draws strictly inside `rect` (the cell box, one or two cells wide) in `color`.
    static func draw(_ scalar: Unicode.Scalar, in rect: CGRect, scale: CGFloat, color: CGColor, context: CGContext) {
        let grid = GlyphGrid(rect: rect, scale: scale)
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect); context.setFillColor(color); context.setStrokeColor(color)
        switch scalar.value {
        case 0x2500...0x257F: BoxGlyphs.draw(scalar.value, grid: grid, context: context)
        case 0x2580...0x259F: BlockGlyphs.draw(scalar.value, grid: grid, context: context)
        default: BrailleGlyphs.draw(scalar.value, grid: grid, context: context)
        }
    }
}

/// A cell measured in whole device pixels. Offsets count from the cell's top-left corner, like bitmap rows, and every
/// fill is snapped to the device grid so neighbouring cells join without seams or overlaps.
struct GlyphGrid {
    let rect: CGRect
    let scale: CGFloat
    /// Cell size in device pixels.
    let width: Int, height: Int
    /// Light stroke thickness in device pixels; heavy is twice that.
    let light: Int
    var heavy: Int { light * 2 }
    init(rect: CGRect, scale: CGFloat) {
        self.rect = rect; self.scale = scale
        width = max(1, Int((rect.width * scale).rounded())); height = max(1, Int((rect.height * scale).rounded()))
        light = max(1, Int((rect.width * scale / 8).rounded()))
    }
    /// The context-space rectangle for a pixel box whose top-left is (`x`, `y`) pixels into the cell.
    func pixels(x: Int, y: Int, width: Int, height: Int) -> CGRect {
        CGRect(x: rect.minX + CGFloat(x) / scale, y: rect.maxY - CGFloat(y + height) / scale, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }
    /// Context-space point for pixel offsets measured from the top-left corner.
    func point(x: CGFloat, y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x / scale, y: rect.maxY - y / scale) }
}
