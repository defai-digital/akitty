import Foundation

/// Emoji clusters arrive as consecutive wcwidth cells because the core does not use grapheme-cluster widths: a ZWJ
/// sequence is one wide cell per joined piece, and a flag is one narrow cell per regional indicator. Joining them
/// here lets the rasterizer draw the whole cluster as one line in the first cell's box instead of three faces or
/// boxed letters, and the absorbed cells keep their columns so following text stays aligned.
enum GlyphClusters {
    /// A cell to draw: `text` may come from several source cells, inside a box `columns` cells wide at `cell.col`.
    struct Drawn {
        let cell: Cell
        let text: String
        let columns: Int
    }

    private static let zwj: Unicode.Scalar = "\u{200D}"

    /// Walks row-major `cells` and joins emoji clusters within a row, omitting the cells they absorb.
    static func merge(_ cells: [Cell]) -> [Drawn] {
        var drawn: [Drawn] = []
        var index = 0
        while index < cells.count {
            let first = cells[index]
            var text = first.text
            var columns = first.wide ? 2 : 1
            var end = first.col + columns
            var next = index + 1
            if text.unicodeScalars.last == zwj {
                while text.unicodeScalars.last == zwj, let joined = follower(cells, from: next, row: first.row, column: end) {
                    text += joined.cell.text
                    next = joined.index + 1
                    end = joined.cell.col + (joined.cell.wide ? 2 : 1)
                }
            } else if isRegionalIndicator(text), let joined = follower(cells, from: next, row: first.row, column: end),
                      isRegionalIndicator(joined.cell.text) {
                text += joined.cell.text
                next = joined.index + 1
                end = joined.cell.col + (joined.cell.wide ? 2 : 1)
                columns = 2
            }
            // A cluster's drawn box covers the spacers of the cells it absorbed, so skip them: they would draw nothing
            // anyway, and leaving them out keeps the merged list one item per visible glyph.
            if next > index + 1 {
                while next < cells.count, cells[next].row == first.row, cells[next].col < end, isBlank(cells[next].text) { next += 1 }
            }
            drawn.append(Drawn(cell: first, text: text, columns: columns))
            index = next
        }
        return drawn
    }

    /// The next non-blank cell that starts exactly at `column`, skipping the blank spacers of a wide cell's span.
    private static func follower(_ cells: [Cell], from start: Int, row: Int, column: Int) -> (index: Int, cell: Cell)? {
        var index = start
        while index < cells.count, cells[index].row == row, cells[index].col < column {
            guard isBlank(cells[index].text) else { return nil }
            index += 1
        }
        guard index < cells.count, cells[index].row == row, cells[index].col == column, !isBlank(cells[index].text) else { return nil }
        return (index, cells[index])
    }

    private static func isBlank(_ text: String) -> Bool { text.isEmpty || text == " " }

    private static func isRegionalIndicator(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return (0x1F1E6...0x1F1FF).contains(scalar.value)
    }
}
