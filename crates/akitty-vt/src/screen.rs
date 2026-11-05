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

#[derive(Clone, Debug)]
pub struct Row {
    pub id: u64,
    pub cells: Vec<Cell>,
    pub wrapped: bool,
    /// A wide glyph wrapped before the last column, leaving padding there.
    pub wrap_padding: bool,
    pub generation: u64,
    history_cost: usize,
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
            .filter(|c| c.width != 0)
            .map(Cell::text)
            .collect()
    }
    fn bytes(&self) -> usize {
        self.cells.capacity() * std::mem::size_of::<Cell>()
            + self
                .cells
                .iter()
                .map(|c| {
                    c.combining.capacity() * std::mem::size_of::<char>()
                        + c.link.as_ref().map_or(0, |s| s.len())
                })
                .sum::<usize>()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Anchor {
    pub row_id: u64,
    pub col: usize,
}

#[derive(Debug)]
pub struct Screen {
    pub rows: Vec<Row>,
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
    spare: Option<Vec<Cell>>,
}

impl Screen {
    pub fn new(cols: usize, rows: usize, history: usize, alternate: bool) -> Self {
        let mut screen = Self {
            rows: Vec::new(),
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
            screen.rows.push(row);
        }
        screen
    }

    pub fn blank(&mut self, background: Color) -> Row {
        let id = self.next_row_id;
        self.next_row_id = self.next_row_id.wrapping_add(1);
        let cells = match self.spare.take() {
            Some(mut cells) if cells.len() == self.cols => {
                cells.fill(Cell::blank(background));
                cells
            }
            _ => vec![Cell::blank(background); self.cols],
        };
        Row {
            id,
            cells,
            wrapped: false,
            wrap_padding: false,
            generation: 0,
            history_cost: 0,
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

    fn recycle(&mut self, row: Row) {
        if row.cells.len() == self.cols {
            self.spare = Some(row.cells);
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
                let removed = self.rows.remove(region.start);
                if history && region.start == 0 {
                    self.remember(removed);
                } else {
                    self.recycle(removed);
                }
                let blank = self.blank(bg);
                self.rows.insert(region.end - 1, blank);
            } else {
                let removed = self.rows.remove(region.end - 1);
                self.recycle(removed);
                let blank = self.blank(bg);
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
        let Some((a, b)) = self.selection_range() else {
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
                if cell.width == 0 && col > 0 {
                    let prev = Position { row, col: col - 1 };
                    prev >= a && prev <= b
                } else if cell.width == 2 {
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
                let overlap = col < content_end && col + usize::from(cell.width) > start;
                if overlap && cell.width != 0 {
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
                    if cell.width == 0 {
                        continue;
                    }
                    let width = usize::from(cell.width).min(cols);
                    if col + width > cols || col == cols {
                        output.wrap_padding = col != cols;
                        output.wrapped = true;
                        rebuilt.push(output);
                        output = self.blank(Color::Background);
                        col = 0;
                    }
                    if let Some(target) = cursor_logical
                        && target >= position
                        && target < position + usize::from(cell.width)
                    {
                        cursor_global = rebuilt.len();
                        cursor_col = col + (target - position).min(width - 1);
                        cursor_found = true;
                        pending_wrap = false;
                    }
                    if let Some(target) = viewport_logical
                        && target >= position
                        && target < position + usize::from(cell.width)
                    {
                        viewport_global = rebuilt.len();
                        viewport_found = true;
                    }
                    if let Some(target) = saved_logical
                        && target >= position
                        && target < position + usize::from(cell.width)
                    {
                        saved_global = rebuilt.len();
                        saved_col = col + (target - position).min(width - 1);
                        saved_found = true;
                        saved_wrap = false;
                    }
                    cell.width = width as u8;
                    output.cells[col] = cell;
                    if width == 2 {
                        output.cells[col + 1] = Cell {
                            width: 0,
                            style: output.cells[col].style,
                            link: output.cells[col].link.clone(),
                            link_id: output.cells[col].link_id,
                            ..Cell::default()
                        };
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
                if row.cells[cols - 1].width == 2 {
                    row.cells[cols - 1] = Cell::default();
                }
            }
        }
        // Trailing unused screen rows do not force the cursor into history when shrinking.
        while all.len() > rows
            && all.last().is_some_and(|row| row.used() == 0)
            && all.len() - 1 > cursor_global
        {
            all.pop();
        }
        while all.len() < rows {
            let row = self.blank(Color::Background);
            all.push(row);
        }
        let history_count = all.len().saturating_sub(rows);
        self.rows = all.split_off(history_count);
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
