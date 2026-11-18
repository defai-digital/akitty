//! Screen storage with bounded history and stable row identities.

use crate::cell::{Cell, Color};
use std::collections::VecDeque;

pub const MAX_HISTORY_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct Position {
    pub row: usize,
    pub col: usize,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cursor {
    pub position: Position,
    pub pending_wrap: bool,
}

/// Distinct side records a row is charged for, maintained as cells are written.
///
/// A row is blanked to a heap-free background, and writes then advance left to right
/// (`prefix`). Everything at or beyond `prefix` is still such a blank, so a run of
/// writes only ever adds identities and tracking stays O(1) per run. Any write that
/// rewrites accounted cells, or a bulk edit, drops the cache and the next `bytes()`
/// recounts exactly.
#[derive(Clone, Copy, Debug)]
struct Charge {
    /// Columns whose cells are reflected in `total`.
    prefix: usize,
    /// Heap bytes of the distinct records inside the prefix.
    total: usize,
    /// Record identities counted so far (compared only, never dereferenced).
    keys: [usize; CHARGE_KEYS],
    used: usize,
}

/// Distinct records tracked per row without allocating. A row normally holds one or
/// two; a row that needs more falls back to an exact recount instead of growing.
const CHARGE_KEYS: usize = 4;

impl Charge {
    const fn fresh() -> Self {
        Self { prefix: 0, total: 0, keys: [0; CHARGE_KEYS], used: 0 }
    }
}

type Spare = Option<(Vec<Cell>, usize, Color, bool)>;

/// A new blank row, reusing the spare cells when they have the screen's width.
fn build_blank(spare: &mut Spare, next_row_id: &mut u64, cols: usize, background: Color) -> Row {
    let id = *next_row_id;
    *next_row_id = next_row_id.wrapping_add(1);
    let cells = match spare.take() {
        Some((mut cells, modified_end, bg, heap)) if cells.len() == cols => {
            let end = if bg == background { modified_end } else { cells.len() };
            refill_blank(&mut cells[..end], heap, background);
            cells
        }
        _ => vec![Cell::blank(background); cols],
    };
    Row {
        id,
        cells,
        wrapped: false,
        wrap_padding: false,
        generation: 0,
        history_cost: 0,
        blank_gen: 0,
        blank_bg: background,
        modified_end: 0,
        modified_gen: 0,
        has_heap: Cell::blank_owns_heap(background),
        charge: if Cell::blank_owns_heap(background) { None } else { Some(Charge::fresh()) },
    }
}

/// Turn `row` into the blank row that `Screen::recycle(row)` followed by
/// `Screen::blank(background)` would produce, in place, so its cells and metadata are
/// not moved through the spare slot.
fn reblank(row: &mut Row, spare: &mut Spare, next_row_id: &mut u64, cols: usize, background: Color) {
    if row.cells.len() != cols {
        // `recycle` keeps no cells of another width, so `blank` uses the spare.
        *row = build_blank(spare, next_row_id, cols, background);
        return;
    }
    let end = if row.blank_bg == background { row.blank_from() } else { row.cells.len() };
    refill_blank(&mut row.cells[..end], row.has_heap, background);
    // `recycle` would have replaced the spare and `blank` taken it.
    *spare = None;
    row.id = *next_row_id;
    *next_row_id = next_row_id.wrapping_add(1);
    row.wrapped = false;
    row.wrap_padding = false;
    row.generation = 0;
    row.history_cost = 0;
    row.blank_gen = 0;
    row.blank_bg = background;
    row.modified_end = 0;
    row.modified_gen = 0;
    row.has_heap = Cell::blank_owns_heap(background);
    row.charge = if row.has_heap { None } else { Some(Charge::fresh()) };
}

/// Fill recycled cells with blanks of `background`. `heap` says whether any of them
/// may own a side record; when neither they nor the blank do, the fill is plain stores.
fn refill_blank(cells: &mut [Cell], heap: bool, background: Color) {
    let blank = Cell::blank(background);
    match blank.packed_word() {
        Some(packed) if !heap => {
            for cell in cells {
                cell.store_heap_free(Cell::from_packed(blank.ch, packed));
            }
        }
        _ => cells.fill(blank),
    }
}

/// Whether `tabs` holds the default stop every eight columns and no other.
fn default_tabs(tabs: &[bool]) -> bool {
    tabs.iter().enumerate().all(|(col, &stop)| stop == (col != 0 && col % 8 == 0))
}

#[derive(Clone, Debug)]
pub struct Row {
    pub id: u64,
    pub cells: Vec<Cell>,
    pub wrapped: bool,
    /// A wide glyph wrapped before the last column, leaving padding there.
    pub wrap_padding: bool,
    pub generation: u64,
    history_cost: usize,
    /// Generation at which the cells were last fully blanked, and the background used.
    /// `blank_gen == generation && blank_bg == bg` means the cells are exactly `cols`
    /// blanks of `bg`, so a repeat blank of the same colour can skip the fill. Any cell
    /// write bumps `generation` and invalidates this; resize mutates cells without a
    /// bump and must call `unmark_blank`.
    blank_gen: u64,
    blank_bg: Color,
    /// Cells beyond this bound still equal the last full blank, including style and
    /// written-space state. Every cell mutation extends it; resize invalidates it.
    modified_end: usize,
    modified_gen: u64,
    /// Whether any cell in this row may own heap (combining marks, a hyperlink, or
    /// presentation kept in a cell's side record).
    /// `false` certifies every cell is heap-free, letting `bytes()` skip the per-cell
    /// scan. It is set when side data is attached and cleared only by a full blank;
    /// a stale `true` merely over-counts (safe), while a stale `false` would
    /// under-count the history budget, so resize conservatively re-sets it.
    has_heap: bool,
    /// Incremental history charge, or `None` when an edit needs an exact recount.
    charge: Option<Charge>,
}

impl Row {
    pub fn used(&self) -> usize {
        self.cells
            .iter()
            .rposition(Cell::occupied)
            .map_or(0, |i| i + 1)
    }
    pub fn text(&self) -> String {
        self.cells
            .iter()
            .filter(|c| c.width() != 0)
            .map(Cell::text)
            .collect()
    }
    /// Bytes this row is charged in the history budget: its cell storage plus the side
    /// records it owns. Records shared by a whole run are counted once; a record shared
    /// with another row is charged in each of them (never an under-count).
    fn bytes(&self) -> usize {
        let base = self.cells.capacity() * std::mem::size_of::<Cell>();
        if !self.has_heap {
            return base;
        }
        match &self.charge {
            Some(charge) => {
                // The incremental charge must equal an independent recount; tests run
                // this check so any missed accounting hook fails loudly.
                #[cfg(test)]
                assert_eq!(
                    charge.total,
                    crate::cell::side_bytes(&self.cells),
                    "row {} incremental charge drifted (prefix {} of {}, heap cells {}, used {})",
                    self.id,
                    charge.prefix,
                    self.cells.len(),
                    self.cells.iter().filter(|c| c.side_bytes() > 0).count(),
                    charge.used
                );
                base + charge.total
            }
            None => base + crate::cell::side_bytes(&self.cells),
        }
    }
    /// Account for `count` cells written at `col` with the side record `side`.
    pub(crate) fn charge_write(&mut self, col: usize, count: usize, side: Option<(usize, usize)>) {
        let Some(charge) = &mut self.charge else { return };
        if count == 0 || col < charge.prefix || col + count > self.cells.len() {
            self.charge = None;
            return;
        }
        if let Some((key, bytes)) = side
            && !charge.keys[..charge.used].contains(&key)
        {
            if charge.used == CHARGE_KEYS {
                self.charge = None;
                return;
            }
            charge.keys[charge.used] = key;
            charge.used += 1;
            charge.total += bytes;
        }
        charge.prefix = charge.prefix.max(col + count);
        #[cfg(test)]
        {
            let actual = crate::cell::side_bytes(&self.cells);
            let cached = self.charge.map_or(actual, |charge| charge.total);
            assert_eq!(
                cached,
                actual,
                "charge_write({col}, {count}) left row {} inconsistent: charge {:?} cells {:?}",
                self.id,
                self.charge.map(|charge| (charge.prefix, charge.total, charge.used)),
                self.cells.iter().map(|cell| (cell.ch, cell.side_bytes())).collect::<Vec<_>>()
            );
        }
    }
    #[cfg(test)]
    pub(crate) fn assert_charge_matches_recount(&self, context: &str) {
        let actual = crate::cell::side_bytes(&self.cells);
        if let Some(charge) = self.charge {
            assert_eq!(
                charge.total, actual,
                "row {} drifted after {context:?} (prefix {} of {}, cells {:?})",
                self.id,
                charge.prefix,
                self.cells.len(),
                self.cells.iter().map(|cell| (cell.ch, cell.side_bytes())).collect::<Vec<_>>()
            );
        }
    }
    /// Drop the cache: the cells changed in a way only a recount can price.
    pub(crate) fn charge_unknown(&mut self) {
        self.charge = None;
    }
    /// The row was rewritten with cells that own no side record (a uniform fill of
    /// plain cells), so nothing is charged while all cells stay above the prefix.
    pub(crate) fn charge_plain(&mut self) {
        self.charge = Some(Charge::fresh());
    }
    /// The row is exactly `bg` blanks again.
    fn charge_blank(&mut self, bg: Color) {
        self.charge = if Cell::blank_owns_heap(bg) { None } else { Some(Charge::fresh()) };
    }
    /// The row's history charge, for accounting tests.
    #[cfg(test)]
    pub(crate) fn bytes_for_test(&self) -> usize {
        self.bytes()
    }
    /// An independent full recount of the same charge, for accounting tests.
    #[cfg(test)]
    pub(crate) fn recount_for_test(&self) -> usize {
        let base = self.cells.capacity() * std::mem::size_of::<Cell>();
        if !self.has_heap {
            return base;
        }
        base + crate::cell::side_bytes(&self.cells)
    }
    /// True when the cells are known to be exactly `cols` blanks of `bg`.
    pub(crate) fn is_blank(&self, bg: Color) -> bool {
        self.blank_gen == self.generation && self.blank_bg == bg
    }
    /// Record that the cells were just fully blanked with `bg` at the current generation.
    ///
    /// A blank cell of an RGB background cannot be packed, so it owns a side record: the
    /// row still owns heap and the flag must stay set. Clearing it unconditionally would
    /// make `bytes()` report base-only and let the history budget be bypassed.
    pub(crate) fn mark_blank(&mut self, bg: Color) {
        self.blank_gen = self.generation;
        self.blank_bg = bg;
        self.has_heap = Cell::blank_owns_heap(bg);
        self.modified_end = 0;
        self.modified_gen = self.generation;
    }
    #[inline]
    pub(crate) fn record_write(&mut self, end: usize, advances: u64) {
        debug_assert!(end <= self.cells.len());
        let previous = self.generation;
        self.generation = self.generation.wrapping_add(advances);
        if self.modified_end == self.cells.len() { return; }
        // An untracked generation change invalidates the prefix certificate.
        if self.modified_gen != previous { self.modified_end = self.cells.len(); return; }
        self.modified_end = self.modified_end.max(end);
        self.modified_gen = self.generation;
    }
    #[inline]
    pub(crate) fn record_full_write(&mut self, advances: u64) {
        self.generation = self.generation.wrapping_add(advances);
        self.modified_end = self.cells.len();
    }
    #[cfg(test)]
    pub(crate) fn modified_end_for_test(&self) -> usize {
        self.modified_end
    }
    /// Clear only the possibly changed prefix when the untouched suffix has the
    /// requested background. Changing the blank colour requires a complete fill.
    pub(crate) fn reset_cells(&mut self, bg: Color) {
        let end = if self.is_blank(bg) { 0 }
            else if self.blank_bg == bg && self.modified_gen == self.generation { self.modified_end }
            else { self.cells.len() };
        self.fill_blank_to(end, bg);
        self.charge_blank(bg);
        self.mark_blank(bg);
    }
    /// Record that a cell in this row now owns heap (a side record with combining
    /// marks, a hyperlink, or presentation the packed word cannot hold).
    /// True when the heap flag certifies that no cell owns a side record.
    #[inline]
    pub(crate) fn heap_free(&self) -> bool {
        !self.has_heap
    }
    /// The column from which every cell still equals the row's last full blank, or the
    /// row length when that certificate is not current.
    #[inline]
    pub(crate) fn blank_from(&self) -> usize {
        if self.modified_gen == self.generation { self.modified_end } else { self.cells.len() }
    }
    pub(crate) fn mark_heap(&mut self) {
        self.has_heap = true;
    }
    /// Install a blank cell, keeping the heap flag honest: an RGB background cannot be
    /// packed, so the blank owns a side record and the row must keep counting it.
    pub(crate) fn put_blank(&mut self, col: usize, bg: Color) {
        self.cells[col] = Cell::blank(bg);
        self.has_heap |= Cell::blank_owns_heap(bg);
        self.charge = None;
    }
    /// Fill a column range with blanks, allocating one shared record for the range.
    pub(crate) fn fill_blank(&mut self, range: std::ops::Range<usize>, bg: Color) {
        let blank = Cell::blank(bg);
        match blank.packed_word() {
            // Neither the old cells nor the blank own heap: a plain store fill.
            Some(packed) if !self.has_heap => {
                for cell in &mut self.cells[range] {
                    cell.store_heap_free(Cell::from_packed(blank.ch, packed));
                }
            }
            _ => self.cells[range].fill(blank),
        }
        self.has_heap |= Cell::blank_owns_heap(bg);
        self.charge = None;
    }
    /// Fill the first `end` columns with blanks.
    pub(crate) fn fill_blank_to(&mut self, end: usize, bg: Color) {
        self.fill_blank(0..end, bg);
    }
    /// Invalidate the blank marker: cells changed without a generation bump (resize).
    /// Use `generation - 1`, not `+ 1`: generation only ever advances by one per write,
    /// so `+ 1` would re-alias `blank_gen == generation` on the very next write and
    /// falsely re-certify a row that now holds text. A past generation is never revisited.
    fn unmark_blank(&mut self) {
        self.blank_gen = self.generation.wrapping_sub(1);
        self.modified_end = self.cells.len();
        self.modified_gen = self.generation;
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Anchor {
    pub row_id: u64,
    pub col: usize,
}

#[derive(Debug)]
pub struct Screen {
    pub rows: VecDeque<Row>,
    pub history: VecDeque<Row>,
    pub cursor: Cursor,
    pub saved_cursor: Cursor,
    pub offset: usize,
    pub selection: Option<(Anchor, Anchor)>,
    pub keyboard_stack: Vec<u8>,
    pub keyboard_flags: u8,
    pub region: std::ops::Range<usize>,
    pub tabs: Vec<bool>,
    pub cols: usize,
    history_limit: usize,
    history_bytes: usize,
    next_row_id: u64,
    /// Recycled cells, the bound past which they are still blanks of the colour, and
    /// whether any of them may own heap.
    spare: Spare,
}

impl Screen {
    pub fn new(cols: usize, rows: usize, history: usize, alternate: bool) -> Self {
        let mut screen = Self {
            rows: VecDeque::new(),
            history: VecDeque::new(),
            cursor: Cursor::default(),
            saved_cursor: Cursor::default(),
            offset: 0,
            selection: None,
            keyboard_stack: Vec::new(),
            keyboard_flags: 0,
            region: 0..rows,
            tabs: (0..cols).map(|c| c != 0 && c % 8 == 0).collect(),
            cols,
            history_limit: history,
            history_bytes: 0,
            next_row_id: if alternate { 1 << 63 } else { 1 },
            spare: None,
        };
        for _ in 0..rows {
            let row = screen.blank(Color::Background);
            screen.rows.push_back(row);
        }
        screen
    }

    pub fn blank(&mut self, background: Color) -> Row {
        build_blank(&mut self.spare, &mut self.next_row_id, self.cols, background)
    }

    /// Blank this screen in place, keeping its allocations. Row ids keep advancing from the
    /// current counter so an anchor or host row identity recorded before the clear never
    /// aliases a new row.
    pub fn clear(&mut self) {
        let cols = self.cols;
        let rows = self.rows.len();
        let mut next_id = self.next_row_id;
        for row in &mut self.rows {
            row.id = next_id;
            next_id = next_id.wrapping_add(1);
            if row.cells.len() != cols {
                row.cells = vec![Cell::blank(Color::Background); cols];
                row.charge_blank(Color::Background);
            } else if !row.is_blank(Color::Background) {
                // A row still certified blank has its blank cells and charge already.
                row.reset_cells(Color::Background);
            }
            row.wrapped = false;
            row.wrap_padding = false;
            row.generation = row.generation.wrapping_add(1);
            row.mark_blank(Color::Background);
            row.history_cost = 0;
        }
        self.next_row_id = next_id;
        self.history.clear();
        self.history_bytes = 0;
        self.cursor = Cursor::default();
        self.saved_cursor = Cursor::default();
        self.offset = 0;
        self.selection = None;
        self.keyboard_stack.clear();
        self.keyboard_flags = 0;
        self.region = 0..rows;
        if self.tabs.len() != cols || !default_tabs(&self.tabs) {
            self.tabs.clear();
            self.tabs.extend((0..cols).map(|c| c != 0 && c % 8 == 0));
        }
    }

    /// Negative indices address history, with -1 immediately before screen row 0.
    pub fn line(&self, row: i32) -> Option<&Row> {
        if row >= 0 {
            return self.rows.get(row as usize);
        }
        let index = self.history.len() as i64 + i64::from(row);
        usize::try_from(index)
            .ok()
            .and_then(|i| self.history.get(i))
    }
    pub fn viewport_line(&self, row: usize) -> Option<&Row> {
        self.line(row as i32 - self.offset as i32)
    }
    pub fn scroll_display(&mut self, lines: i32) {
        self.offset =
            (self.offset as i64 + i64::from(lines)).clamp(0, self.history.len() as i64) as usize;
    }
    pub fn scroll_to(&mut self, row: i32) {
        if row + (self.offset as i32) < 0 {
            self.offset = (-row) as usize;
        } else if row + self.offset as i32 >= self.rows.len() as i32 {
            self.offset = (self.rows.len() as i32 - 1 - row).max(0) as usize;
        }
        self.offset = self.offset.min(self.history.len());
    }

    fn reblank(&mut self, row: &mut Row, background: Color) {
        reblank(row, &mut self.spare, &mut self.next_row_id, self.cols, background);
    }
    fn recycle(&mut self, row: Row) {
        if row.cells.len() == self.cols {
            let end = if row.modified_gen == row.generation { row.modified_end } else { row.cells.len() };
            self.spare = Some((row.cells, end, row.blank_bg, row.has_heap));
        }
    }
    fn remember(&mut self, mut row: Row) {
        if self.history_limit == 0 {
            self.recycle(row);
            return;
        }
        row.history_cost = row.bytes();
        self.history_bytes += row.history_cost;
        self.history.push_back(row);
        if self.offset != 0 {
            self.offset += 1;
        }
        while self.history.len() > self.history_limit || self.history_bytes > MAX_HISTORY_BYTES {
            if let Some(old) = self.history.pop_front() {
                self.history_bytes = self.history_bytes.saturating_sub(old.history_cost);
                self.recycle(old);
            } else {
                break;
            }
        }
        self.offset = self.offset.min(self.history.len());
    }

    /// Test-only: the currently accounted history bytes, to assert the heap flag
    /// never lets a combining/link row under-count the history budget.
    #[cfg(test)]
    pub(crate) fn history_bytes_for_test(&self) -> usize {
        self.history_bytes
    }

    #[cfg(test)]
    pub(crate) fn state_for_test(&self) -> String {
        let rows = |rows: &VecDeque<Row>| rows.iter().map(|r| {
            format!("{:?}", (r.id, &r.cells, r.wrapped, r.wrap_padding, r.generation,
                             r.history_cost, r.blank_gen, r.blank_bg, r.has_heap))
        }).collect::<Vec<_>>();
        format!("{:?}{:?}{:?}{:?}", rows(&self.rows), rows(&self.history),
            (self.cursor, self.saved_cursor, self.offset, self.selection, &self.keyboard_stack,
             self.keyboard_flags, &self.region, &self.tabs, self.cols),
            (self.history_limit, self.history_bytes, self.next_row_id,
             self.spare.as_ref().map(|(cells, _, bg, _)| (cells, bg))))
    }

    #[cfg(test)]
    pub(crate) fn force_full_reset_for_test(&mut self) {
        for row in self.rows.iter_mut().chain(self.history.iter_mut()) {
            row.modified_end = row.cells.len();
        }
        if let Some((cells, end, _, heap)) = &mut self.spare { *end = cells.len(); *heap = true; }
    }

    /// Rotate a region. Positive counts move text up; only a top-anchored region
    /// can add history. The returned count is the movement actually performed.
    pub fn scroll(
        &mut self,
        region: std::ops::Range<usize>,
        lines: i32,
        history: bool,
        bg: Color,
    ) -> i32 {
        if region.start >= region.end || region.end > self.rows.len() {
            return 0;
        }
        let count = lines.unsigned_abs().min((region.end - region.start) as u32) as usize;
        for _ in 0..count {
            if lines > 0 {
                let remember = history && region.start == 0 && self.history_limit != 0;
                if !remember && region.start == 0 && region.end == self.rows.len() {
                    // The whole screen: rotate the top row to the bottom and blank it
                    // where it lands, instead of removing and inserting a row.
                    // At exactly its length the deque rotates by moving its head alone;
                    // with spare capacity each rotation would copy a row.
                    if self.rows.capacity() != self.rows.len() {
                        self.rows.shrink_to_fit();
                    }
                    self.rows.rotate_left(1);
                    let last = self.rows.back_mut().expect("validated scroll region");
                    reblank(last, &mut self.spare, &mut self.next_row_id, self.cols, bg);
                    continue;
                }
                let removed = self.rows.remove(region.start).expect("validated scroll region");
                let blank = if remember {
                    self.remember(removed);
                    self.blank(bg)
                } else {
                    let mut removed = removed;
                    self.reblank(&mut removed, bg);
                    removed
                };
                // A region ending at the bottom row appends; `insert` would take the
                // general wrap-aware move path for what is a push.
                if region.end == self.rows.len() + 1 {
                    self.rows.push_back(blank);
                } else {
                    self.rows.insert(region.end - 1, blank);
                }
            } else {
                let mut blank = self.rows.remove(region.end - 1).expect("validated scroll region");
                self.reblank(&mut blank, bg);
                self.rows.insert(region.start, blank);
            }
        }
        (count as i32) * lines.signum()
    }

    pub fn clear_history(&mut self) {
        self.history.clear();
        self.history_bytes = 0;
        self.offset = 0;
    }

    pub fn select(&mut self, start: Position, end: Position) {
        self.selection = self
            .viewport_line(start.row)
            .zip(self.viewport_line(end.row))
            .map(|(a, b)| {
                (
                    Anchor {
                        row_id: a.id,
                        col: start.col.min(self.cols - 1),
                    },
                    Anchor {
                        row_id: b.id,
                        col: end.col.min(self.cols - 1),
                    },
                )
            });
    }
    fn anchor_position(&self, anchor: Anchor) -> Option<Position> {
        self.history
            .iter()
            .chain(&self.rows)
            .position(|row| row.id == anchor.row_id)
            .map(|row| Position {
                row,
                col: anchor.col,
            })
    }
    pub fn selection_range(&self) -> Option<(Position, Position)> {
        let (a, b) = self.selection?;
        let (a, b) = (self.anchor_position(a)?, self.anchor_position(b)?);
        Some(if a <= b { (a, b) } else { (b, a) })
    }
    pub fn selected(&self, line: i32, col: usize) -> bool {
        self.selected_in(self.selection_range(), line, col)
    }
    /// `selected` with the anchor scan already resolved, so a snapshot pays for it once
    /// instead of once per cell.
    pub fn selected_in(&self, range: Option<(Position, Position)>, line: i32, col: usize) -> bool {
        let Some((a, b)) = range else {
            return false;
        };
        let row = i64::from(line) + self.history.len() as i64;
        let Ok(row) = usize::try_from(row) else {
            return false;
        };
        let point = Position { row, col };
        let selected = point >= a && point <= b;
        if selected {
            return true;
        }
        // Selecting either half of a wide cell highlights both columns.
        self.line(line)
            .and_then(|r| r.cells.get(col))
            .is_some_and(|cell| {
                if cell.width() == 0 && col > 0 {
                    let prev = Position { row, col: col - 1 };
                    prev >= a && prev <= b
                } else if cell.width() == 2 {
                    let next = Position { row, col: col + 1 };
                    next >= a && next <= b
                } else {
                    false
                }
            })
    }
    pub fn selection_text(&self) -> String {
        let Some((a, b)) = self.selection_range() else {
            return String::new();
        };
        let mut out = String::new();
        for (index, row) in self
            .history
            .iter()
            .chain(&self.rows)
            .enumerate()
            .skip(a.row)
            .take(b.row - a.row + 1)
        {
            let start = if index == a.row { a.col } else { 0 };
            let end = if index == b.row { b.col + 1 } else { self.cols };
            let content_end = end.min(self.cols - usize::from(row.wrapped && row.wrap_padding));
            let mut text = String::new();
            for (col, cell) in row.cells.iter().enumerate() {
                let overlap = col < content_end && col + usize::from(cell.width()) > start;
                if overlap && cell.width() != 0 {
                    text.push_str(&cell.text());
                }
            }
            if !row.wrapped && (end == self.cols || index != b.row) {
                text.truncate(text.trim_end_matches(' ').len());
            }
            out.push_str(&text);
            if index != b.row && !row.wrapped {
                out.push('\n');
            }
        }
        out
    }

    /// Reflow logical wrapped lines and relocate the cursor into the new grid.
    /// History is rebuilt through the same resource accounting as ordinary scroll.
    pub fn resize(&mut self, cols: usize, rows: usize, reflow: bool) -> i32 {
        let old_history = self.history.len();
        let scrolled = self.offset != 0;
        let old_viewport_row = old_history.saturating_sub(self.offset);
        let mut viewport_global = old_viewport_row;
        let old_cols = self.cols;
        let old_cursor_row = old_history + self.cursor.position.row;
        let old_cursor_col = self.cursor.position.col;
        let old_wrap = self.cursor.pending_wrap;
        let old_saved_row = old_history + self.saved_cursor.position.row;
        let old_saved_col = self.saved_cursor.position.col;
        let old_saved_wrap = self.saved_cursor.pending_wrap;
        let mut all: Vec<Row> = self.history.drain(..).chain(self.rows.drain(..)).collect();
        self.history_bytes = 0;
        self.cols = cols;
        let mut cursor_global = old_cursor_row;
        let mut cursor_col = old_cursor_col.min(cols - 1);
        let mut pending_wrap = old_wrap && cols == old_cols;
        let mut saved_global = old_saved_row;
        let mut saved_col = old_saved_col.min(cols - 1);
        let mut saved_wrap = old_saved_wrap && cols == old_cols;
        if reflow && cols != old_cols {
            let mut rebuilt: Vec<Row> = Vec::new();
            let mut logical = Vec::<Cell>::new();
            let mut logical_id = 0;
            let mut cursor_logical: Option<usize> = None;
            let mut saved_logical: Option<usize> = None;
            let mut viewport_logical: Option<usize> = None;
            let source_len = all.len();
            for (index, row) in all.into_iter().enumerate() {
                if logical.is_empty() {
                    logical_id = row.id;
                }
                let mut used = if row.wrapped {
                    old_cols - usize::from(row.wrap_padding)
                } else {
                    row.used()
                };
                if index == old_cursor_row {
                    used = used.max(old_cursor_col + usize::from(old_wrap));
                    cursor_logical = Some(logical.len() + old_cursor_col + usize::from(old_wrap));
                }
                if index == old_saved_row {
                    used = used.max(old_saved_col + usize::from(old_saved_wrap));
                    saved_logical =
                        Some(logical.len() + old_saved_col + usize::from(old_saved_wrap));
                }
                if index == old_viewport_row {
                    viewport_logical = Some(logical.len());
                }
                logical.extend(row.cells.into_iter().take(used));
                if row.wrapped && index + 1 != source_len {
                    continue;
                }
                let mut output = self.blank(Color::Background);
                output.id = logical_id;
                let mut col = 0;
                let mut cursor_found = false;
                let mut saved_found = false;
                let mut viewport_found = false;
                for (position, mut cell) in logical.drain(..).enumerate() {
                    if cell.width() == 0 {
                        continue;
                    }
                    let width = usize::from(cell.width()).min(cols);
                    if col + width > cols || col == cols {
                        output.wrap_padding = col != cols;
                        output.wrapped = true;
                        rebuilt.push(output);
                        output = self.blank(Color::Background);
                        col = 0;
                    }
                    if let Some(target) = cursor_logical
                        && target >= position
                        && target < position + usize::from(cell.width())
                    {
                        cursor_global = rebuilt.len();
                        cursor_col = col + (target - position).min(width - 1);
                        cursor_found = true;
                        pending_wrap = false;
                    }
                    if let Some(target) = viewport_logical
                        && target >= position
                        && target < position + usize::from(cell.width())
                    {
                        viewport_global = rebuilt.len();
                        viewport_found = true;
                    }
                    if let Some(target) = saved_logical
                        && target >= position
                        && target < position + usize::from(cell.width())
                    {
                        saved_global = rebuilt.len();
                        saved_col = col + (target - position).min(width - 1);
                        saved_found = true;
                        saved_wrap = false;
                    }
                    cell.set_width(width as u8);
                    output.cells[col] = cell;
                    if width == 2 {
                        output.cells[col + 1] = output.cells[col].spacer();
                    }
                    col += width;
                }
                if cursor_logical.is_some() && !cursor_found {
                    cursor_global = rebuilt.len();
                    cursor_col = col.min(cols - 1);
                    pending_wrap = col == cols;
                }
                if viewport_logical.is_some() && !viewport_found {
                    viewport_global = rebuilt.len();
                }
                if saved_logical.is_some() && !saved_found {
                    saved_global = rebuilt.len();
                    saved_col = col.min(cols - 1);
                    saved_wrap = col == cols;
                }
                cursor_logical = None;
                saved_logical = None;
                viewport_logical = None;
                rebuilt.push(output);
            }
            all = rebuilt;
        } else {
            for row in &mut all {
                row.cells.resize(cols, Cell::default());
                row.cells.truncate(cols);
                if row.cells[cols - 1].width() == 2 {
                    row.cells[cols - 1] = Cell::default();
                }
            }
        }
        // Resize rebuilds, truncates and reflows cells directly, outside the write hooks,
        // and `remember` below prices them. Charge them by recount.
        for row in &mut all {
            row.charge = None;
        }
        // Trailing unused screen rows do not force the cursor into history when shrinking.
        while all.len() > rows
            && all.last().is_some_and(|row| row.used() == 0)
            && all.len() - 1 > cursor_global
        {
            all.pop();
        }
        // The cursor's own line never goes to history: when occupied rows below it
        // no longer fit, those rows are dropped instead of moving the cursor onto
        // a different line.
        all.truncate(cursor_global + rows);
        while all.len() < rows {
            let row = self.blank(Color::Background);
            all.push(row);
        }
        // Resize moves cells between rows without a generation bump, so a row that was
        // heap-free may now hold combining/link cells. Conservatively re-arm the heap
        // flag before remember() recomputes history_cost; over-counting is safe, but a
        // stale false here would under-count the history budget.
        // Invalidate blank/range certificates before history eviction can recycle
        // a rebuilt row whose cells moved without a generation advance.
        for row in &mut all {
            row.has_heap = true;
            row.unmark_blank();
        }
        let history_count = all.len().saturating_sub(rows);
        self.rows = all.split_off(history_count).into();
        // Rebuilding retained history is not new terminal output. In particular,
        // remember() must not advance a scrolled viewport for each retained row.
        self.offset = 0;
        for row in all {
            self.remember(row);
        }
        self.cursor.position = Position {
            row: cursor_global.saturating_sub(history_count).min(rows - 1),
            col: cursor_col,
        };
        self.cursor.pending_wrap = pending_wrap;
        self.saved_cursor = Cursor {
            position: Position {
                row: saved_global.saturating_sub(history_count).min(rows - 1),
                col: saved_col,
            },
            pending_wrap: saved_wrap,
        };
        self.region = 0..rows;
        self.tabs.resize_with(cols, || false);
        for col in old_cols..cols {
            self.tabs[col] = col != 0 && col % 8 == 0;
        }
        self.offset = if scrolled {
            history_count
                .saturating_sub(viewport_global)
                .min(self.history.len())
        } else {
            0
        };
        self.selection = None;
        history_count as i32 - old_history as i32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scroll_moves_rows_like_a_reference_for_every_region() {
        // Up and down scrolls of every region and count, including regions that end at
        // the bottom row (the append path) and one row above it.
        for rows in 1..=5usize {
            for start in 0..rows {
                for end in start + 1..=rows {
                    for lines in [-6i32, -2, -1, 1, 2, 6] {
                        let mut screen = Screen::new(3, rows, 0, false);
                        let mut model: Vec<Option<u64>> = screen.rows.iter().map(|r| Some(r.id)).collect();
                        let moved = screen.scroll(start..end, lines, false, Color::Background);
                        let count = (lines.unsigned_abs() as usize).min(end - start);
                        assert_eq!(moved, count as i32 * lines.signum());
                        for _ in 0..count {
                            if lines > 0 {
                                model.remove(start);
                                model.insert(end - 1, None);
                            } else {
                                model.remove(end - 1);
                                model.insert(start, None);
                            }
                        }
                        let actual: Vec<Option<u64>> = screen.rows.iter().map(|r| {
                            let original = r.id < rows as u64 + 1 && model.contains(&Some(r.id));
                            original.then_some(r.id)
                        }).collect();
                        assert_eq!(actual, model, "rows={rows} region={start}..{end} lines={lines}");
                    }
                }
            }
        }
    }

    #[test]
    fn untracked_generation_changes_force_full_clear_and_recycle() {
        let mut screen = Screen::new(12, 1, 0, false);
        for tracked_write_after in [false, true] {
            let row = &mut screen.rows[0];
            row.cells[10].ch = 'X';
            row.cells[10].set_written(true);
            row.generation = row.generation.wrapping_add(1);
            if tracked_write_after {
                row.record_write(1, 1);
                row.cells[0].ch = 'Y';
            }
            row.reset_cells(Color::Background);
            assert!(row.cells.iter().all(|c| c == &Cell::default()));
        }
        let mut row = screen.rows.pop_front().unwrap();
        row.cells[11].set_written(true);
        row.cells[11].ch = 'Z';
        row.generation = row.generation.wrapping_add(1);
        screen.recycle(row);
        let row = screen.blank(Color::Background);
        assert!(row.cells.iter().all(|c| c == &Cell::default()));
    }
}
