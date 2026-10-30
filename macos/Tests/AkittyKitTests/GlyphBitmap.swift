import CoreGraphics
@testable import AkittyKit

/// Draws a grid of characters with `CellGlyphs` (white on black) and exposes device pixels with a top-left origin.
struct GlyphBitmap {
    let width: Int, height: Int
    let cellWidth: Int, cellHeight: Int
    /// Device pixels of untouched background around the grid.
    let pad: Int
    private var luma: [UInt8]

    /// `rows` hold one character per cell (a space leaves the cell empty); cells are `cell` points at `scale`.
    init(rows: [String], cell: CGSize = CGSize(width: 8, height: 16), scale: Int = 1, pad: Int = 2) {
        let columns = rows.map { $0.count }.max() ?? 1
        cellWidth = Int(cell.width) * scale; cellHeight = Int(cell.height) * scale; self.pad = pad * scale
        let w = columns * cellWidth + 2 * self.pad, h = rows.count * cellHeight + 2 * self.pad
        width = w; height = h
        var data = [UInt8](repeating: 0, count: w * h)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            let points = CGSize(width: CGFloat(w) / CGFloat(scale), height: CGFloat(h) / CGFloat(scale))
            let padding = CGFloat(pad)
            for (row, line) in rows.enumerated() {
                for (col, character) in line.enumerated() {
                    guard let scalar = character.unicodeScalars.first, scalar != " " else { continue }
                    let box = CGRect(x: padding + CGFloat(col) * cell.width, y: points.height - padding - CGFloat(row + 1) * cell.height, width: cell.width, height: cell.height)
                    CellGlyphs.draw(scalar, in: box, scale: CGFloat(scale), color: CGColor(gray: 1, alpha: 1), context: context)
                }
            }
        }
        luma = data
    }
    /// Brightness 0...255 of the device pixel at bitmap coordinates (`x`, `y`).
    func value(x: Int, y: Int) -> UInt8 { luma[y * width + x] }
    /// Device-pixel bitmap coordinates of the top-left corner of the cell at `row`, `col`.
    func origin(row: Int, col: Int) -> (x: Int, y: Int) { (pad + col * cellWidth, pad + row * cellHeight) }
    /// Whether the pixel (`x`, `y`) device pixels into the cell at `row`, `col` is at least half lit.
    func painted(row: Int, col: Int, x: Int, y: Int) -> Bool { let o = origin(row: row, col: col); return value(x: o.x + x, y: o.y + y) >= 128 }
    /// Mean brightness (0...1) over a device-pixel box inside the cell at `row`, `col`.
    func coverage(row: Int, col: Int, x: Range<Int>, y: Range<Int>) -> Double {
        let o = origin(row: row, col: col)
        var sum = 0, count = 0
        for py in y { for px in x { sum += Int(value(x: o.x + px, y: o.y + py)); count += 1 } }
        return count == 0 ? 0 : Double(sum) / Double(count * 255)
    }
    /// Whether every pixel outside the cells (the `pad` ring) is still background.
    var padIsEmpty: Bool {
        for y in 0..<height { for x in 0..<width where (x < pad || y < pad || x >= width - pad || y >= height - pad) && value(x: x, y: y) != 0 { return false } }
        return true
    }
}
