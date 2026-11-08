//! Kitty Unicode image placeholders, decoded from the public graphics protocol.
//! The numeric alphabet is independently generated from Unicode 6.0.0 data.
//! See https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders.

use akitty_vt::cell::Color;

/// The placeholder codepoint a virtual placement is drawn through.
pub const PLACEHOLDER: char = '\u{10EEEE}';

include!("placeholder_table.rs");

/// Index of a diacritic in the table above, which is the row or column it encodes.
pub fn diacritic_index(c: char) -> Option<u32> {
    DIACRITICS.binary_search(&u32::from(c)).ok().map(|index| index as u32)
}

/// The image-id low bits (or placement id) a cell colour encodes: truecolour
/// packs the channels, 256-colour uses the index, named colours mean none.
pub fn color_id(color: Color) -> u32 {
    match color {
        Color::Rgb(rgb) => Color::pack(rgb),
        Color::Indexed(index) => u32::from(index),
        Color::Foreground | Color::Background => 0,
    }
}

/// Fills the [row, column, image-id high byte] slots from a cell's combining
/// marks; marks outside the table are ignored and the remaining ones shift up.
pub fn marks(chars: &[char]) -> [Option<u32>; 3] {
    let mut slots = [None, None, None];
    let mut next = 0;
    for c in chars {
        if next == 3 { break; }
        if let Some(index) = diacritic_index(*c) {
            slots[next] = Some(index);
            next += 1;
        }
    }
    slots
}

/// One placeholder cell of a screen row, with its colour ids decoded.
#[derive(Clone)]
pub struct Cell {
    pub col: usize,
    /// Low 24 bits of the image id from the foreground colour; never 0 here.
    pub low: u32,
    /// Placement id from the underline colour.
    pub placement: u32,
    /// Decoded [row, column, image-id high byte] marks.
    pub marks: [Option<u32>; 3],
}

/// The cell grid a virtual placement reserved plus its image size in pixels.
pub struct Grid {
    pub cols: u32,
    pub rows: u32,
    pub image_w: u32,
    pub image_h: u32,
}

/// Part of one virtual placement a contiguous run of placeholder cells shows.
pub struct Fragment {
    pub image: u32,
    pub row: usize,
    pub col: usize,
    pub cols: u32,
    pub sx: u32,
    pub sy: u32,
    pub sw: u32,
    pub sh: u32,
    pub ox: u32,
    pub oy: u32,
    pub dw: u32,
    pub dh: u32,
}

/// Decodes one screen row of placeholder cells into the fragments their runs
/// show. `resolve` maps (image id, placement id) to the virtual placement's
/// cell grid; runs of unknown images are skipped. Every fragment is returned
/// with the placement id it decoded from. Pure: no terminal state is touched.
pub fn decode_row<F>(row: usize, cells: &[Cell], cell_px: (u32, u32), resolve: &mut F) -> Vec<(Fragment, u32)>
where
    F: FnMut(u32, u32) -> Option<Grid>,
{
    // Apply the protocol's three inheritance cases. Explicit coordinates always
    // start a new position; only absent suffix marks can come from a neighbor.
    let mut decoded = Vec::with_capacity(cells.len());
    for (index, cell) in cells.iter().enumerate() {
        let mut coordinates = cell.marks.map(|mark| mark.unwrap_or(0));
        if index > 0 {
            let left = &cells[index - 1];
            let [left_row, left_col, left_high] = decoded[index - 1];
            let adjacent = left.col.checked_add(1) == Some(cell.col)
                && left.low == cell.low && left.placement == cell.placement;
            if adjacent {
                match cell.marks {
                    [None, None, None] => coordinates = [left_row, left_col + 1, left_high],
                    [Some(r), None, None] if r == left_row =>
                        coordinates = [r, left_col + 1, left_high],
                    [Some(r), Some(c), None] if r == left_row && c == left_col + 1 =>
                        coordinates = [r, c, left_high],
                    _ => {}
                }
            }
        }
        decoded.push(coordinates);
    }
    // Group decoded cells into contiguous runs and clip each run to the fitted
    // image rectangle; runs that fall fully in the letterbox margin vanish.
    let mut out = Vec::new();
    let mut index = 0;
    while index < cells.len() {
        let [row_in_grid, col_in_grid, high] = decoded[index];
        let cell = &cells[index];
        // Only the low 8 bits of the high mark fit a 32-bit image id.
        let image = (high & 0xff) << 24 | cell.low;
        let Some(grid) = resolve(image, cell.placement) else { index += 1; continue };
        if row_in_grid >= grid.rows || col_in_grid >= grid.cols { index += 1; continue; }
        let mut end = index + 1;
        while end < cells.len() {
            let [next_row, next_col, next_high] = decoded[end];
            let next = &cells[end];
            if next.col != cell.col + (end - index)
                || next_high != high
                || next.low != cell.low
                || next.placement != cell.placement
                || next_row != row_in_grid
                || next_col != col_in_grid + (end - index) as u32
                || next_col >= grid.cols
            {
                break;
            }
            end += 1;
        }
        let cols = (end - index) as u32;
        if let Some(fragment) = fit(image, (row, cell.col), cols, &grid, cell_px, (row_in_grid, col_in_grid)) {
            out.push((fragment, cell.placement));
        }
        index = end;
    }
    out
}

/// Clips one run to the image fitted into the virtual placement's cell grid:
/// the source keeps its aspect ratio, is centred, and the run shows the
/// intersection of its cells with the drawn rectangle.
/// `at` is the run's screen (row, column) and `start` its first cell's (row, column) in the placement grid.
fn fit(image: u32, at: (usize, usize), cols: u32, grid: &Grid, cell_px: (u32, u32), start: (u32, u32)) -> Option<Fragment> {
    let ((row, col), (grid_row, grid_col)) = (at, start);
    let (cell_w, cell_h) = (u64::from(cell_px.0.max(1)), u64::from(cell_px.1.max(1)));
    let (cols_total, rows_total) = (u64::from(grid.cols), u64::from(grid.rows));
    let (image_w, image_h) = (u64::from(grid.image_w), u64::from(grid.image_h));
    if cols_total == 0 || rows_total == 0 || image_w == 0 || image_h == 0 {
        return None;
    }
    let (width, height) = (cols_total * cell_w, rows_total * cell_h);
    let (drawn_w, drawn_h) = if width * image_h <= height * image_w {
        (width, (width * image_h).div_ceil(image_w))
    } else {
        ((height * image_w).div_ceil(image_h), height)
    };
    let (margin_x, margin_y) = ((width - drawn_w) / 2, (height - drawn_h) / 2);
    let (x0, x1) = (u64::from(grid_col) * cell_w, (u64::from(grid_col) + u64::from(cols)) * cell_w);
    let (y0, y1) = (u64::from(grid_row) * cell_h, u64::from(grid_row + 1) * cell_h);
    let (left, right) = (x0.max(margin_x), x1.min(margin_x + drawn_w));
    let (top, bottom) = (y0.max(margin_y), y1.min(margin_y + drawn_h));
    if left >= right || top >= bottom { return None; }
    let sx = (left - margin_x) * image_w / drawn_w;
    let sy = (top - margin_y) * image_h / drawn_h;
    let sw = (right - margin_x) * image_w / drawn_w - sx;
    let sh = (bottom - margin_y) * image_h / drawn_h - sy;
    Some(Fragment {
        image,
        row,
        col,
        cols,
        sx: sx as u32,
        sy: sy as u32,
        sw: sw as u32,
        sh: sh as u32,
        ox: (left - x0) as u32,
        oy: (top - y0) as u32,
        dw: (right - left) as u32,
        dh: (bottom - top) as u32,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(index: usize) -> char {
        char::from_u32(DIACRITICS[index]).unwrap()
    }
    fn cell(col: usize, low: u32, placement: u32, marks: [Option<u32>; 3]) -> Cell {
        Cell { col, low, placement, marks }
    }

    #[test]
    fn diacritics_are_sorted_and_indices_round_trip() {
        for pair in DIACRITICS.windows(2) {
            assert!(pair[0] < pair[1], "table must stay sorted for binary search");
        }
        for (index, code) in DIACRITICS.iter().enumerate() {
            assert_eq!(diacritic_index(char::from_u32(*code).unwrap()), Some(index as u32));
        }
        assert_eq!(diacritic_index('a'), None);
        assert_eq!(diacritic_index('\u{0306}'), None, "a combining mark outside the table");
        assert_eq!(diacritic_index(PLACEHOLDER), None);
    }

    #[test]
    fn marks_fill_slots_in_order_and_skip_invalid_diacritics() {
        assert_eq!(marks(&[d(0), d(2)]), [Some(0), Some(2), None]);
        assert_eq!(marks(&['x', d(0), 'y', d(2), d(5)]), [Some(0), Some(2), Some(5)]);
        assert_eq!(marks(&[]), [None, None, None]);
        assert_eq!(marks(&[d(296), d(0), d(1), d(2)]), [Some(296), Some(0), Some(1)]);
    }

    #[test]
    fn color_ids_come_from_truecolour_and_256_colour_values() {
        let rgb = |r, g, b| Color::rgb(r, g, b);
        assert_eq!(color_id(rgb(1, 2, 3)), 0x010203);
        assert_eq!(color_id(rgb(0, 0, 0)), 0);
        assert_eq!(color_id(Color::Indexed(200)), 200);
        assert_eq!(color_id(Color::Foreground), 0);
    }

    #[test]
    fn letterboxed_wide_image_yields_expected_source_rects_per_row() {
        // A 32x16 image in a 4x2 grid of 8x16 cells: the grid is square, the
        // image is wide, so the fit is 32x16 px centred with 8 px bars.
        let grid = Grid { cols: 4, rows: 2, image_w: 32, image_h: 16 };
        let mut resolve = |image: u32, placement: u32| {
            assert_eq!((image, placement), (5, 1));
            Some(Grid { cols: grid.cols, rows: grid.rows, image_w: grid.image_w, image_h: grid.image_h })
        };
        let row = |row: usize| {
            (0..4)
                .map(|col| cell(col, 5, 1, [Some(row as u32), Some(col as u32), None]))
                .collect::<Vec<_>>()
        };
        let top = decode_row(0, &row(0), (8, 16), &mut resolve);
        assert_eq!(top.len(), 1);
        let f = &top[0].0;
        assert_eq!((f.row, f.col, f.cols, f.sx, f.sy, f.sw, f.sh, f.ox, f.oy, f.dw, f.dh),
            (0, 0, 4, 0, 0, 32, 8, 0, 8, 32, 8));
        let bottom = decode_row(1, &row(1), (8, 16), &mut resolve);
        let f = &bottom[0].0;
        assert_eq!((f.row, f.sy, f.oy), (1, 8, 0));
        assert_eq!((f.sx, f.sw, f.sh, f.dw, f.dh), (0, 32, 8, 32, 8));
    }

    #[test]
    fn runs_entirely_in_the_letterbox_margin_produce_nothing() {
        // Same wide image in a taller 4x3 grid: rows 0 and 2 are pure margin.
        let mut resolve = |_: u32, _: u32| Some(Grid { cols: 4, rows: 3, image_w: 32, image_h: 16 });
        let margin = (0..4).map(|col| cell(col, 5, 1, [Some(0), Some(col as u32), None])).collect::<Vec<_>>();
        assert!(decode_row(0, &margin, (8, 16), &mut resolve).is_empty());
        let middle = (0..4).map(|col| cell(col, 5, 1, [Some(1), Some(col as u32), None])).collect::<Vec<_>>();
        assert_eq!(decode_row(2, &middle, (8, 16), &mut resolve).len(), 1);
    }

    #[test]
    fn missing_marks_continue_the_run_from_the_left_neighbour() {
        let mut resolve = |image: u32, _: u32| (image == 5).then_some(Grid { cols: 4, rows: 1, image_w: 32, image_h: 32 });
        let cells = [
            cell(0, 5, 1, [Some(0), Some(0), None]),
            cell(1, 5, 1, [None, None, None]),
            cell(2, 5, 1, [None, None, None]),
            cell(3, 5, 1, [None, None, None]),
        ];
        let run = decode_row(0, &cells, (8, 16), &mut resolve);
        assert_eq!(run.len(), 1);
        assert_eq!((run[0].0.col, run[0].0.cols, run[0].0.sw), (0, 4, 32));
        // A different image id or a gap in columns breaks the run; a cell that cannot continue starts its own run
        // with missing marks read as 0 (image 6 is unknown, so only image 5's two runs remain).
        let cells = [
            cell(0, 5, 1, [Some(0), Some(0), None]),
            cell(1, 6, 1, [None, None, None]),
            cell(3, 5, 1, [None, None, None]),
        ];
        // The image fills the 4x1 grid exactly here, so single cells are never pure letterbox margin.
        let mut resolve = |image: u32, _: u32| (image == 5).then_some(Grid { cols: 4, rows: 1, image_w: 32, image_h: 16 });
        let broken = decode_row(0, &cells, (8, 16), &mut resolve);
        assert_eq!(broken.len(), 2);
        assert_eq!((broken[0].0.col, broken[0].0.cols, broken[1].0.col, broken[1].0.sx), (0, 1, 3, 0));
    }

    #[test]
    fn third_diacritic_supplies_the_image_id_high_byte() {
        let seen = std::cell::Cell::new(0);
        let mut resolve = |image: u32, placement: u32| {
            seen.set(image);
            assert_eq!(placement, 3);
            Some(Grid { cols: 1, rows: 1, image_w: 8, image_h: 16 })
        };
        let cells = [cell(0, 5, 3, [Some(0), Some(0), Some(2)])];
        let run = decode_row(0, &cells, (8, 16), &mut resolve);
        assert_eq!(seen.get(), 0x0200_0005);
        assert_eq!(run[0].0.image, 0x0200_0005);
        // A high mark above 255 wraps inside the 32-bit id instead of panicking.
        let cells = [cell(0, 5, 3, [Some(0), Some(0), Some(296)])];
        assert_eq!(decode_row(0, &cells, (8, 16), &mut resolve)[0].0.image, 0x2800_0005);
    }

    #[test]
    fn unknown_images_and_out_of_grid_marks_are_skipped() {
        let mut resolve = |image: u32, _: u32| (image == 5).then_some(Grid { cols: 2, rows: 1, image_w: 16, image_h: 16 });
        let unknown = [cell(0, 9, 1, [Some(0), Some(0), None])];
        assert!(decode_row(0, &unknown, (8, 16), &mut resolve).is_empty());
        let outside = [cell(0, 5, 1, [Some(0), Some(5), None]), cell(1, 5, 1, [Some(1), Some(0), None])];
        assert!(decode_row(0, &outside, (8, 16), &mut resolve).is_empty());
    }
}
