//! Terminal behavior implemented against public terminal protocol specifications.
//!
//! Every input chunk is applied in order. Content movement events describe actual
//! grid mutations, so consumers never need to simulate scrolling a second time.

use crate::cell::{self, Cell, Color, Combining, Link, Palette, Style};
use crate::parser::{Action, Csi, Input, Parser, StringKind, Terminator};
use crate::screen::{Cursor, Position, Screen};
use base64::Engine;
use std::ops::Range;
use std::sync::Arc;
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

pub const MAX_CELLS: usize = 1_048_576;
pub const SYNC_TIMEOUT_MS: u64 = 150;
const MAX_SYNC_MEMORY: usize = 2 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Reply(Vec<u8>),
    Title(String),
    Bell,
    Clipboard(String),
    Scroll {
        alternate: bool,
        top: usize,
        bottom: usize,
        lines: i32,
        history: usize,
        to_history: bool,
    },
    Resize {
        history_delta: i32,
        history: usize,
        /// Rows removed from the top of the alternate screen, which has no history.
        alternate_delta: i32,
        /// New viewport row count; placements anchored on discarded rows must go.
        rows: usize,
    },
    ClearVisible {
        alternate: bool,
        rows: usize,
    },
    ClearHistory,
    Alternate(bool),
    Reset,
    Osc(Vec<u8>),
    Apc(Vec<u8>),
    Dcs(Vec<u8>),
}

#[derive(Clone, Debug)]
pub struct Modes {
    pub alternate: bool,
    pub cursor_visible: bool,
    pub cursor_blink: bool,
    pub app_cursor: bool,
    pub app_keypad: bool,
    pub bracketed_paste: bool,
    pub focus_reporting: bool,
    pub mouse_click: bool,
    pub mouse_drag: bool,
    pub mouse_motion: bool,
    pub mouse_sgr: bool,
    pub mouse_utf8: bool,
    pub origin: bool,
    pub wrap: bool,
    pub insert: bool,
    pub newline: bool,
    pub reverse_video: bool,
    pub cursor_shape: u8,
    pub modify_other_keys: u8,
    pub alt_escape: bool,
    pub alternate_scroll: bool,
    pub grapheme_clusters: bool,
}

impl Default for Modes {
    fn default() -> Self {
        Self {
            alternate: false,
            cursor_visible: true,
            cursor_blink: true,
            app_cursor: false,
            app_keypad: false,
            bracketed_paste: false,
            focus_reporting: false,
            mouse_click: false,
            mouse_drag: false,
            mouse_motion: false,
            mouse_sgr: false,
            mouse_utf8: false,
            origin: false,
            wrap: true,
            insert: false,
            newline: false,
            reverse_video: false,
            cursor_shape: 0,
            modify_other_keys: 0,
            alt_escape: true,
            alternate_scroll: true,
            grapheme_clusters: false,
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct SavedState {
    style: Style,
    origin: bool,
    wrap: bool,
    charsets: [bool; 4],
    charset: usize,
    single_shift: Option<usize>,
}

impl Default for SavedState {
    fn default() -> Self {
        Self {
            style: Style::default(),
            origin: false,
            wrap: true,
            charsets: [false; 4],
            charset: 0,
            single_shift: None,
        }
    }
}

#[derive(Debug)]
pub struct Terminal {
    parser: Parser,
    main: Screen,
    alternate: Screen,
    pub modes: Modes,
    pub palette: Palette,
    pub style: Style,
    pub cell_pixels: (u32, u32),
    pub revision: u64,
    pub title: String,
    link: Option<Arc<Link>>,
    link_id: u32,
    title_stack: Vec<String>,
    saved_state: [SavedState; 2],
    charsets: [bool; 4],
    charset: usize,
    single_shift: Option<usize>,
    last_printed: Option<char>,
    sync_deadline: Option<u64>,
    sync_actions: Vec<Action>,
    sync_bytes: usize,
    grapheme_supported: bool,
    grapheme_target: Option<Position>,
    cluster_scratch: String,
    pub preserve_erased_screen: bool,
    pub title_max_bytes: usize,
    pub title_max_chars: usize,
}

impl Terminal {
    pub fn validate_size(cols: usize, rows: usize) -> Result<(), &'static str> {
        if cols == 0
            || rows == 0
            || cols > 4096
            || rows > 4096
            || cols.checked_mul(rows).is_none_or(|n| n > MAX_CELLS)
        {
            Err("terminal dimensions exceed resource limits")
        } else {
            Ok(())
        }
    }
    pub fn new(cols: usize, rows: usize, history: usize) -> Result<Self, &'static str> {
        Self::validate_size(cols, rows)?;
        Ok(Self {
            parser: Parser::default(),
            main: Screen::new(cols, rows, history.min(100_000), false),
            alternate: Screen::new(cols, rows, 0, true),
            modes: Modes::default(),
            palette: Palette::default(),
            style: Style::default(),
            cell_pixels: (8, 16),
            revision: 0,
            title: String::new(),
            link: None,
            link_id: 0,
            title_stack: Vec::new(),
            saved_state: [SavedState::default(); 2],
            charsets: [false; 4],
            charset: 0,
            single_shift: None,
            last_printed: None,
            sync_deadline: None,
            sync_actions: Vec::new(),
            sync_bytes: 0,
            grapheme_supported: false,
            grapheme_target: None,
            cluster_scratch: String::new(),
            preserve_erased_screen: true,
            title_max_bytes: crate::parser::MAX_STRING_BYTES,
            title_max_chars: 128,
        })
    }
    pub fn screen(&self) -> &Screen {
        self.screen_for(self.modes.alternate)
    }
    /// Read either retained screen without changing the active buffer or modes.
    pub fn screen_for(&self, alternate: bool) -> &Screen {
        if alternate {
            &self.alternate
        } else {
            &self.main
        }
    }
    pub fn screen_mut(&mut self) -> &mut Screen {
        if self.modes.alternate {
            &mut self.alternate
        } else {
            &mut self.main
        }
    }
    pub fn cols(&self) -> usize {
        self.screen().cols
    }
    pub fn rows(&self) -> usize {
        self.screen().rows.len()
    }
    pub fn cursor(&self) -> Position {
        self.screen().cursor.position
    }
    pub fn sync_deadline(&self) -> Option<u64> {
        self.sync_deadline
    }
    pub fn keyboard_flags(&self) -> u8 {
        self.screen().keyboard_flags
    }
    pub fn enable_grapheme_support(&mut self, enabled: bool) {
        self.grapheme_supported = enabled;
        self.modes.grapheme_clusters = enabled;
        self.grapheme_target = None;
    }

    pub fn feed(&mut self, bytes: &[u8], now_ms: u64, mut emit: impl FnMut(Event)) {
        self.expire_sync(now_ms, &mut emit);
        let mut parser = std::mem::take(&mut self.parser);
        parser.feed_runs(bytes, |input| match input {
            Input::Ascii(bytes) => self.print_ascii(bytes, now_ms, &mut emit),
            Input::Csi(csi) => {
                let sync_control = csi.prefix == Some(b'?') && csi.intermediates.is_empty()
                    && matches!(csi.final_byte, b'h' | b'l')
                    && csi.params.iter().any(|p| p.first() == Some(&Some(2026)));
                if self.sync_deadline.is_some() || sync_control {
                    self.dispatch(Action::Csi(std::mem::take(csi)), now_ms, &mut emit);
                } else {
                    self.grapheme_target = None;
                    self.csi(csi, &mut emit);
                }
            }
            Input::Action(action) => self.dispatch(action, now_ms, &mut emit),
        });
        self.parser = parser;
        if !bytes.is_empty() {
            self.revision = self.revision.wrapping_add(1);
        }
    }

    pub fn expire_sync(&mut self, now_ms: u64, mut emit: impl FnMut(Event)) -> bool {
        if self
            .sync_deadline
            .is_some_and(|deadline| deadline <= now_ms)
        {
            self.flush_sync(&mut emit);
            self.revision = self.revision.wrapping_add(1);
            true
        } else {
            false
        }
    }
    fn flush_sync(&mut self, emit: &mut impl FnMut(Event)) {
        self.sync_deadline = None;
        self.sync_bytes = 0;
        // Synchronized TUIs defer scalar actions. Reassemble their ordinary text
        // at flush time so they also benefit from row writes, with bounded scratch.
        let mut ascii = [0u8; 8192];
        let mut count = 0;
        for action in std::mem::take(&mut self.sync_actions) {
            if let Action::Print(ch @ ' '..='~') = action {
                ascii[count] = ch as u8;
                count += 1;
                if count == ascii.len() {
                    self.print_ascii(&ascii, 0, emit);
                    count = 0;
                }
                continue;
            }
            if count > 0 { self.print_ascii(&ascii[..count], 0, emit); count = 0; }
            self.apply(action, emit);
        }
        if count > 0 { self.print_ascii(&ascii[..count], 0, emit); }
    }
    fn dispatch(&mut self, action: Action, now: u64, emit: &mut impl FnMut(Event)) {
        if let Action::Csi(csi) = &action
            && csi.prefix == Some(b'?')
            && csi.intermediates.is_empty()
            && matches!(csi.final_byte, b'h' | b'l')
            && csi.params.len() > 1
            && csi
                .params
                .iter()
                .any(|parameter| parameter.first() == Some(&Some(2026)))
        {
            // Mode lists have the same left-to-right semantics as individual
            // commands, including starting or flushing synchronized output.
            for parameter in &csi.params {
                self.dispatch(
                    Action::Csi(Csi {
                        params: vec![parameter.clone()],
                        ..csi.clone()
                    }),
                    now,
                    emit,
                );
            }
            return;
        }
        if let Action::Csi(csi) = &action
            && csi.prefix == Some(b'?')
            && csi.intermediates.is_empty()
            && csi.params.len() == 1
            && csi.value(0, 0) == 2026
        {
            if csi.final_byte == b'h' {
                self.sync_deadline = Some(now.saturating_add(SYNC_TIMEOUT_MS));
                return;
            }
            if csi.final_byte == b'l' {
                self.flush_sync(emit);
                return;
            }
        }
        if self.sync_deadline.is_some() {
            self.sync_bytes += std::mem::size_of::<Action>()
                + match &action {
                    Action::String { payload, .. } => payload.len(),
                    Action::Csi(csi) => csi
                        .params
                        .iter()
                        .map(|p| p.len() * std::mem::size_of::<Option<u16>>())
                        .sum(),
                    _ => 0,
                };
            self.sync_actions.push(action);
            if self.sync_bytes >= MAX_SYNC_MEMORY {
                self.flush_sync(emit);
            }
        } else {
            self.apply(action, emit);
        }
    }
    fn apply(&mut self, action: Action, emit: &mut impl FnMut(Event)) {
        if !matches!(&action, Action::Print(_)) {
            self.grapheme_target = None;
        }
        match action {
            Action::Print(ch) => self.print(ch, emit),
            Action::Control(byte) => match byte {
                7 => emit(Event::Bell),
                8 => {
                    let cursor = &mut self.screen_mut().cursor;
                    cursor.position.col = cursor.position.col.saturating_sub(1);
                    cursor.pending_wrap = false;
                }
                9 => self.tab(1, false),
                10..=12 => {
                    self.linefeed(emit);
                    if self.modes.newline {
                        self.screen_mut().cursor.position.col = 0;
                    }
                }
                13 => {
                    let cursor = &mut self.screen_mut().cursor;
                    cursor.position.col = 0;
                    cursor.pending_wrap = false;
                }
                14 => self.charset = 1,
                15 => self.charset = 0,
                _ => {}
            },
            Action::Escape {
                intermediates,
                final_byte,
            } => self.escape(&intermediates, final_byte, emit),
            Action::Csi(csi) => self.csi(&csi, emit),
            Action::String {
                kind,
                payload,
                terminator,
            } => match kind {
                StringKind::Osc => self.osc(&payload, terminator, emit),
                StringKind::Apc => emit(Event::Apc(payload)),
                StringKind::Dcs => self.dcs(payload, emit),
                _ => {}
            },
        }
    }
    fn clear_wide_at(&mut self, row: usize, col: usize, bg: Color) {
        let cols = self.cols();
        let line = &mut self.screen_mut().rows[row];
        line.record_full_write(1);
        let cells = &mut line.cells;
        if cells[col].width == 0 && col > 0 {
            cells[col - 1] = Cell::blank(bg);
        }
        if cells[col].width == 2 && col + 1 < cols {
            cells[col + 1] = Cell::blank(bg);
        }
        cells[col] = Cell::blank(bg);
    }
    /// Write ordinary text a row at a time, leaving protocol-sensitive cases on the
    /// scalar path. The generation count and final grapheme target match scalar writes.
    fn print_ascii(&mut self, mut bytes: &[u8], now: u64, emit: &mut impl FnMut(Event)) {
        while !bytes.is_empty() {
            let cursor = self.screen().cursor;
            let complex_cluster = self.modes.grapheme_clusters && self.grapheme_target.is_some_and(|pos| {
                let previous = &self.screen().rows[pos.row].cells[pos.col];
                !previous.ch.is_ascii() || !previous.combining.is_empty()
            });
            if self.sync_deadline.is_some() || self.modes.insert || self.single_shift.is_some()
                || self.charsets[self.charset] || self.link.is_some() || cursor.pending_wrap || complex_cluster {
                self.dispatch(Action::Print(char::from(bytes[0])), now, emit);
                bytes = &bytes[1..];
                continue;
            }
            let pos = cursor.position;
            let cols = self.cols();
            let available = bytes.len().min(cols - pos.col);
            let row = &self.screen().rows[pos.row];
            let count = row.cells[pos.col..pos.col + available].iter().take_while(|cell| cell.width == 1).count();
            if count == 0 {
                self.print(char::from(bytes[0]), emit);
                bytes = &bytes[1..];
                continue;
            }
            let style = self.style;
            let screen = self.screen_mut();
            let row = &mut screen.rows[pos.row];
            row.record_write(pos.col + count, count as u64);
            for (cell, &byte) in row.cells[pos.col..pos.col + count].iter_mut().zip(bytes) {
                *cell = Cell { ch: char::from(byte), width: 1, style, link: None, combining: Combining::new(), written: true };
            }
            screen.cursor.position.col = (pos.col + count).min(cols - 1);
            screen.cursor.pending_wrap = pos.col + count == cols;
            self.last_printed = Some(char::from(bytes[count - 1]));
            self.grapheme_target = Some(Position { row: pos.row, col: pos.col + count - 1 });
            bytes = &bytes[count..];
        }
    }
    fn print(&mut self, mut ch: char, emit: &mut impl FnMut(Event)) {
        let charset = self.single_shift.take().unwrap_or(self.charset);
        if self.charsets[charset] {
            ch = dec_graphic(ch);
        }
        if self.modes.grapheme_clusters && self.join_grapheme(ch, emit) {
            return;
        }
        let width = ch.width().unwrap_or(0).min(2).min(self.cols());
        if width == 0 {
            let cursor = self.screen().cursor;
            let mut col = cursor.position.col;
            if !cursor.pending_wrap {
                col = col.saturating_sub(1);
            }
            let row = &mut self.screen_mut().rows[cursor.position.row];
            if row.cells[col].width == 0 {
                col = col.saturating_sub(1);
            }
            if row.cells[col].combining.len() < cell::MAX_COMBINING {
                row.record_full_write(1);
                row.cells[col].combining.push(ch);
                row.cells[col].written = true;
                row.mark_heap();
            }
            return;
        }
        if self.screen().cursor.pending_wrap || self.cursor().col + width > self.cols() {
            if self.modes.wrap {
                let row = self.cursor().row;
                self.screen_mut().rows[row].wrap_padding = !self.screen().cursor.pending_wrap;
                self.screen_mut().rows[row].wrapped = true;
                self.screen_mut().cursor.position.col = 0;
                self.linefeed(emit);
            } else {
                self.screen_mut().cursor.pending_wrap = false;
            }
        }
        let pos = self.cursor();
        let width = width.min(self.cols());
        if pos.col + width > self.cols() {
            return;
        }
        if self.modes.insert {
            self.edit_chars(width, true, false);
        }
        // Pre-clearing cells that will both be overwritten is redundant unless a
        // wide neighbour outside the span needs repair. Preserve the generation
        // advances of the scalar clear path even when the assignments are skipped.
        let cells = &self.screen().rows[pos.row].cells;
        let contained = if width == 1 { cells[pos.col].width == 1 }
            else { cells[pos.col].width != 0 && cells[pos.col + 1].width != 2 };
        if contained {
            self.screen_mut().rows[pos.row].record_full_write(width as u64);
        } else {
            self.clear_wide_at(pos.row, pos.col, self.style.bg);
            if width == 2 {
                self.clear_wide_at(pos.row, pos.col + 1, self.style.bg);
            }
        }
        let style = self.style;
        let link = self.link.clone();
        self.screen_mut().rows[pos.row].cells[pos.col] = Cell {
            ch,
            width: width as u8,
            style,
            link: link.clone(),
            combining: Combining::new(),
            written: true,
        };
        if width == 2 {
            self.screen_mut().rows[pos.row].cells[pos.col + 1] = Cell {
                width: 0,
                style,
                link,
                ..Cell::default()
            };
        }
        if self.link.is_some() {
            self.screen_mut().rows[pos.row].mark_heap();
        }
        let cols = self.cols();
        let cursor = &mut self.screen_mut().cursor;
        cursor.position.col = (pos.col + width).min(cols - 1);
        cursor.pending_wrap = pos.col + width >= cols;
        self.last_printed = Some(ch);
        self.grapheme_target = Some(pos);
    }
    fn join_grapheme(&mut self, ch: char, emit: &mut impl FnMut(Event)) -> bool {
        let Some(mut position) = self.grapheme_target else {
            return false;
        };
        {
            let previous = &self.screen().rows[position.row].cells[position.col];
            if ch.is_ascii() && previous.ch.is_ascii() && previous.combining.is_empty() {
                return false;
            }
        }
        // Build the candidate cluster in a reused buffer instead of allocating a fresh
        // String for every printed non-ASCII character. It is moved back out below and
        // restored on every early return.
        let mut cluster = std::mem::take(&mut self.cluster_scratch);
        cluster.clear();
        let previous = &self.screen().rows[position.row].cells[position.col];
        if previous.width != 0 {
            cluster.push(previous.ch);
            cluster.extend(&previous.combining);
        }
        cluster.push(ch);
        if cluster.graphemes(true).nth(1).is_some() {
            self.cluster_scratch = cluster;
            return false;
        }
        if previous.combining.len() >= cell::MAX_COMBINING {
            self.cluster_scratch = cluster;
            return true;
        }
        let mut cell = previous.clone();
        let old_width = usize::from(cell.width);
        let mut width = cluster.width().clamp(1, 2).min(self.cols());
        // DECAWM off: keep the cluster inside the last column instead of
        // wrapping and advancing a row (print() clamps the same way).
        if position.col + width > self.cols() && !self.modes.wrap {
            width = self.cols() - position.col;
        }
        self.cluster_scratch = cluster;
        cell.combining.push(ch);
        cell.width = width as u8;
        if position.col + width > self.cols() {
            self.clear_wide_at(position.row, position.col, cell.style.bg);
            self.screen_mut().rows[position.row].wrapped = true;
            self.screen_mut().rows[position.row].wrap_padding = true;
            self.screen_mut().cursor.position.col = 0;
            self.linefeed(emit);
            position = self.cursor();
        }
        if width != old_width {
            self.clear_wide_at(position.row, position.col, cell.style.bg);
            if width == 2 {
                self.clear_wide_at(position.row, position.col + 1, cell.style.bg);
            }
        }
        let trail = Cell {
            width: 0,
            style: cell.style,
            link: cell.link.clone(),
            ..Cell::default()
        };
        let row = &mut self.screen_mut().rows[position.row];
        row.record_full_write(1);
        row.cells[position.col] = cell;
        if width == 2 {
            row.cells[position.col + 1] = trail;
        }
        row.mark_heap();
        let cols = self.cols();
        self.screen_mut().cursor = Cursor {
            position: Position {
                row: position.row,
                col: (position.col + width).min(cols - 1),
            },
            pending_wrap: position.col + width >= cols,
        };
        self.grapheme_target = Some(position);
        self.last_printed = Some(ch);
        true
    }
    fn scroll(
        &mut self,
        region: Range<usize>,
        lines: i32,
        to_history: bool,
        emit: &mut impl FnMut(Event),
    ) {
        let alternate = self.modes.alternate;
        let to_history = to_history && !alternate && region.start == 0;
        let bg = self.style.bg;
        let moved = self
            .screen_mut()
            .scroll(region.clone(), lines, to_history, bg);
        if moved != 0 {
            emit(Event::Scroll {
                alternate,
                top: region.start,
                bottom: region.end,
                lines: moved,
                history: self.screen().history.len(),
                to_history,
            });
        }
    }
    fn linefeed(&mut self, emit: &mut impl FnMut(Event)) {
        let pos = self.cursor();
        let region = self.screen().region.clone();
        if pos.row + 1 == region.end {
            self.scroll(region, 1, true, emit);
        } else if pos.row + 1 < self.rows() {
            self.screen_mut().cursor.position.row += 1;
        }
        self.screen_mut().cursor.pending_wrap = false;
    }
    fn reverse_index(&mut self, emit: &mut impl FnMut(Event)) {
        let region = self.screen().region.clone();
        if self.cursor().row == region.start {
            self.scroll(region, -1, false, emit);
        } else {
            self.screen_mut().cursor.position.row = self.cursor().row.saturating_sub(1);
        }
        self.screen_mut().cursor.pending_wrap = false;
    }
    fn tab(&mut self, count: usize, backward: bool) {
        for _ in 0..count.min(self.cols()) {
            let start = self.cursor().col;
            let col = if backward {
                (0..start)
                    .rev()
                    .find(|&i| self.screen().tabs[i])
                    .unwrap_or(0)
            } else {
                (start + 1..self.cols())
                    .find(|&i| self.screen().tabs[i])
                    .unwrap_or(self.cols() - 1)
            };
            self.screen_mut().cursor.position.col = col;
        }
        self.screen_mut().cursor.pending_wrap = false;
    }
    fn save_cursor(&mut self) {
        self.screen_mut().saved_cursor = self.screen().cursor;
        self.saved_state[usize::from(self.modes.alternate)] = SavedState {
            style: self.style,
            origin: self.modes.origin,
            wrap: self.modes.wrap,
            charsets: self.charsets,
            charset: self.charset,
            single_shift: self.single_shift,
        };
    }
    fn restore_cursor(&mut self) {
        self.screen_mut().cursor = self.screen().saved_cursor;
        let saved = self.saved_state[usize::from(self.modes.alternate)];
        self.style = saved.style;
        self.modes.origin = saved.origin;
        self.modes.wrap = saved.wrap;
        self.charsets = saved.charsets;
        self.charset = saved.charset;
        self.single_shift = saved.single_shift;
    }
    fn escape(&mut self, intermediate: &[u8], byte: u8, emit: &mut impl FnMut(Event)) {
        if let [slot @ (b'(' | b')' | b'*' | b'+')] = intermediate {
            let index = match slot {
                b'(' => 0,
                b')' => 1,
                b'*' => 2,
                _ => 3,
            };
            self.charsets[index] = byte == b'0';
            return;
        }
        if intermediate == b"#" && byte == b'8' {
            for row in &mut self.screen_mut().rows {
                row.wrapped = false;
                row.record_full_write(1);
                row.cells.fill(Cell {
                    ch: 'E',
                    written: true,
                    ..Cell::default()
                });
            }
            return;
        }
        if !intermediate.is_empty() {
            return;
        }
        match byte {
            b'7' => self.save_cursor(),
            b'8' => self.restore_cursor(),
            b'D' => self.linefeed(emit),
            b'E' => {
                self.screen_mut().cursor.position.col = 0;
                self.linefeed(emit);
            }
            b'M' => self.reverse_index(emit),
            b'H' => {
                let col = self.cursor().col;
                self.screen_mut().tabs[col] = true;
            }
            b'=' => self.modes.app_keypad = true,
            b'>' => self.modes.app_keypad = false,
            b'N' => self.single_shift = Some(2),
            b'O' => self.single_shift = Some(3),
            b'c' => self.reset(emit),
            b'Z' => emit(Event::Reply(b"\x1b[?62;22c".to_vec())),
            _ => {}
        }
    }
    fn goto(&mut self, row: usize, col: usize, origin: bool) {
        let row = if origin && self.modes.origin {
            row.saturating_add(self.screen().region.start)
                .min(self.screen().region.end - 1)
        } else {
            row.min(self.rows() - 1)
        };
        let col = col.min(self.cols() - 1);
        self.screen_mut().cursor = Cursor {
            position: Position { row, col },
            pending_wrap: false,
        };
    }
    fn vertical(&mut self, count: usize, up: bool, cr: bool) {
        let pos = self.cursor();
        let region = self.screen().region.clone();
        let inside = region.contains(&pos.row);
        let low = if inside { region.start } else { 0 };
        let high = if inside {
            region.end - 1
        } else {
            self.rows() - 1
        };
        let row = if up {
            pos.row.saturating_sub(count).max(low)
        } else {
            pos.row.saturating_add(count).min(high)
        };
        self.goto(row, if cr { 0 } else { pos.col }, false);
    }
    fn erase(&mut self, row: usize, range: Range<usize>) {
        let cols = self.cols();
        let bg = self.style.bg;
        let start = range.start.min(cols);
        let end = range.end.min(cols);
        if start < end {
            if start == 0 && end == cols {
                let row = &mut self.screen_mut().rows[row];
                row.reset_cells(bg);
                row.generation = row.generation.wrapping_add(1);
                row.mark_blank(bg);
            } else {
                self.clear_wide_at(row, start, bg);
                if end < cols && self.screen().rows[row].cells[end].width == 0 {
                    self.clear_wide_at(row, end, bg);
                }
                self.screen_mut().rows[row].record_write(end, 0);
                self.screen_mut().rows[row].cells[start..end].fill(Cell::blank(bg));
            }
        }
        if end == cols {
            self.screen_mut().rows[row].wrapped = false;
            self.screen_mut().rows[row].wrap_padding = false;
        }
    }
    fn erase_display(&mut self, mode: u16, emit: &mut impl FnMut(Event)) {
        let pos = self.cursor();
        let rows = self.rows();
        let cols = self.cols();
        match mode {
            0 => {
                self.erase(pos.row, pos.col..cols);
                for row in pos.row + 1..rows {
                    self.erase(row, 0..cols);
                }
            }
            1 => {
                for row in 0..pos.row {
                    self.erase(row, 0..cols);
                }
                self.erase(pos.row, 0..pos.col + 1);
            }
            2 => {
                emit(Event::ClearVisible {
                    alternate: self.modes.alternate,
                    rows,
                });
                if !self.modes.alternate && self.preserve_erased_screen {
                    let used = self
                        .screen()
                        .rows
                        .iter()
                        .rposition(|row| row.used() != 0)
                        .map_or(0, |i| i + 1);
                    self.scroll(0..rows, used as i32, true, emit);
                }
                for row in 0..rows {
                    self.erase(row, 0..cols);
                }
            }
            3 => {
                self.screen_mut().clear_history();
                emit(Event::ClearHistory);
            }
            _ => {}
        }
    }
    fn edit_chars(&mut self, count: usize, insert: bool, erase_only: bool) {
        let pos = self.cursor();
        let cols = self.cols();
        let count = count.min(cols - pos.col);
        let blank = Cell::blank(self.style.bg);
        self.screen_mut().rows[pos.row].record_full_write(1);
        // ICH, DCH and ECH edit in place; the next print must not wrap first.
        self.screen_mut().cursor.pending_wrap = false;
        let cells = &mut self.screen_mut().rows[pos.row].cells;
        if erase_only {
            self.erase(pos.row, pos.col..pos.col + count);
            return;
        }
        if insert {
            cells[pos.col..].rotate_right(count);
            cells[pos.col..pos.col + count].fill(blank.clone());
        } else {
            cells[pos.col..].rotate_left(count);
            cells[cols - count..].fill(blank.clone());
        }
        // Edits can split either boundary of a wide cell. Repair orphan halves.
        for col in pos.col.saturating_sub(1)..cols {
            if cells[col].width == 2 && (col + 1 == cols || cells[col + 1].width != 0)
                || cells[col].width == 0 && (col == 0 || cells[col - 1].width != 2)
            {
                cells[col] = blank.clone();
            }
        }
    }
    fn csi(&mut self, c: &Csi, emit: &mut impl FnMut(Event)) {
        let n = c.count(0);
        let pos = self.cursor();
        if c.intermediates == b"$" && c.final_byte == b'p' {
            for param in &c.params {
                let mode = param.first().copied().flatten().unwrap_or(0);
                let status = self
                    .mode(mode, c.prefix != Some(b'?'))
                    .map_or(0, |set| if set { 1 } else { 2 });
                emit(Event::Reply(
                    format!(
                        "\x1b[{}{mode};{status}$y",
                        if c.prefix == Some(b'?') { "?" } else { "" }
                    )
                    .into_bytes(),
                ));
            }
            return;
        }
        if c.intermediates == b" " && c.final_byte == b'q' {
            self.modes.cursor_shape = c.value(0, 0).min(6) as u8;
            self.modes.cursor_blink = c.value(0, 0) < 2 || c.value(0, 0) % 2 == 1;
            return;
        }
        if c.intermediates == b"!" && c.final_byte == b'p' {
            self.style = Style::default();
            self.modes.origin = false;
            self.modes.insert = false;
            self.modes.app_cursor = false;
            self.modes.app_keypad = false;
            self.modes.wrap = true;
            self.screen_mut().region = 0..self.rows();
            return;
        }
        if !c.intermediates.is_empty() {
            return;
        }
        if c.final_byte == b'u' && c.prefix.is_some() {
            self.keyboard(c, emit);
            return;
        }
        if matches!(c.final_byte, b'h' | b'l') {
            for p in &c.params {
                self.set_mode(
                    p.first().copied().flatten().unwrap_or(0),
                    c.prefix != Some(b'?'),
                    c.final_byte == b'h',
                    emit,
                );
            }
            return;
        }
        match (c.prefix, c.final_byte) {
            (None, b'A') => self.vertical(n, true, false),
            (None, b'B' | b'e') => self.vertical(n, false, false),
            (None, b'C' | b'a') => self.goto(pos.row, pos.col.saturating_add(n), false),
            (None, b'D') => self.goto(pos.row, pos.col.saturating_sub(n), false),
            (None, b'E') => self.vertical(n, false, true),
            (None, b'F') => self.vertical(n, true, true),
            (None, b'G' | b'`') => self.goto(pos.row, n - 1, false),
            (None, b'd') => self.goto(n - 1, pos.col, true),
            (None, b'H' | b'f') => self.goto(n - 1, c.count(1) - 1, true),
            (None, b'I') => self.tab(n, false),
            (None, b'Z') => self.tab(n, true),
            (None, b'J') => {
                self.erase_display(c.value(0, 0), emit);
                self.screen_mut().cursor.pending_wrap = false;
            }
            (None, b'K') => {
                match c.value(0, 0) {
                    0 => self.erase(pos.row, pos.col..self.cols()),
                    1 => self.erase(pos.row, 0..pos.col + 1),
                    2 => self.erase(pos.row, 0..self.cols()),
                    _ => {}
                }
                self.screen_mut().cursor.pending_wrap = false;
            }
            (None, b'@') => self.edit_chars(n, true, false),
            (None, b'P') => self.edit_chars(n, false, false),
            (None, b'X') => self.edit_chars(n, false, true),
            (None, b'L' | b'M') => {
                let region = self.screen().region.clone();
                if region.contains(&pos.row) {
                    self.scroll(
                        pos.row..region.end,
                        (n as i32) * if c.final_byte == b'L' { -1 } else { 1 },
                        false,
                        emit,
                    );
                    // IL and DL return the cursor to the left margin (VT510, xterm).
                    self.goto(pos.row, 0, false);
                }
            }
            (None, b'S' | b'T') => self.scroll(
                self.screen().region.clone(),
                (n as i32) * if c.final_byte == b'S' { 1 } else { -1 },
                c.final_byte == b'S',
                emit,
            ),
            (None, b'b') => {
                if let Some(ch) = self.last_printed {
                    for _ in 0..n.min(MAX_CELLS) {
                        self.print(ch, emit);
                    }
                }
            }
            (None, b'g') => match c.value(0, 0) {
                0 => self.screen_mut().tabs[pos.col] = false,
                3 => self.screen_mut().tabs.fill(false),
                _ => {}
            },
            (None, b'm') => self.sgr(&c.params),
            (Some(b'>'), b'm') if c.value(0, 0) == 4 => {
                self.modes.modify_other_keys = c.value(1, 0).min(2) as u8
            }
            (None, b'r') => {
                let start = n - 1;
                let bottom = c.value(1, 0);
                let end = if bottom == 0 { self.rows() } else { usize::from(bottom).min(self.rows()) };
                // Equal margins are invalid and must not move the cursor.
                if start + 1 < end {
                    self.screen_mut().region = start..end;
                    self.goto(0, 0, true);
                }
            }
            (None, b's') => self.save_cursor(),
            (None, b'u') => self.restore_cursor(),
            (None | Some(b'?'), b'n') if c.value(0, 0) == 6 => {
                // Both CPR forms report coordinates in the current origin mode.
                let row = if self.modes.origin {
                    pos.row.saturating_sub(self.screen().region.start)
                } else {
                    pos.row
                };
                emit(Event::Reply(
                    format!("\x1b[{}{};{}R", if c.prefix.is_some() { "?" } else { "" }, row + 1, pos.col + 1)
                        .into_bytes(),
                ));
            }
            (None, b'n') if c.value(0, 0) == 5 => emit(Event::Reply(b"\x1b[0n".to_vec())),
            (None, b'c') if c.value(0, 0) == 0 => emit(Event::Reply(b"\x1b[?62;22c".to_vec())),
            (Some(b'>'), b'c') => emit(Event::Reply(b"\x1b[>1;139;0c".to_vec())),
            (Some(b'='), b'c') => emit(Event::Reply(b"\x1bP!|414b4954\x1b\\".to_vec())),
            (Some(b'>'), b'q') => emit(Event::Reply(b"\x1bP>|AkiTTY\x1b\\".to_vec())),
            (None, b't') => match c.value(0, 0) {
                14 => emit(Event::Reply(
                    format!(
                        "\x1b[4;{};{}t",
                        self.rows() as u64 * u64::from(self.cell_pixels.1),
                        self.cols() as u64 * u64::from(self.cell_pixels.0)
                    )
                    .into_bytes(),
                )),
                16 => emit(Event::Reply(
                    format!("\x1b[6;{};{}t", self.cell_pixels.1, self.cell_pixels.0).into_bytes(),
                )),
                18 => emit(Event::Reply(
                    format!("\x1b[8;{};{}t", self.rows(), self.cols()).into_bytes(),
                )),
                22 => {
                    if self.title_stack.len() < 16 {
                        self.title_stack.push(self.title.clone());
                    }
                }
                23 => {
                    if let Some(title) = self.title_stack.pop() {
                        self.title = title.clone();
                        emit(Event::Title(title));
                    }
                }
                _ => {}
            },
            _ => {}
        }
    }

    pub fn mode(&self, mode: u16, ansi: bool) -> Option<bool> {
        if ansi {
            return match mode {
                4 => Some(self.modes.insert),
                20 => Some(self.modes.newline),
                _ => None,
            };
        }
        Some(match mode {
            1 => self.modes.app_cursor,
            3 => false,
            5 => self.modes.reverse_video,
            6 => self.modes.origin,
            7 => self.modes.wrap,
            12 => self.modes.cursor_blink,
            25 => self.modes.cursor_visible,
            47 | 1047 | 1049 => self.modes.alternate,
            66 => self.modes.app_keypad,
            1000 => self.modes.mouse_click,
            1002 => self.modes.mouse_drag,
            1003 => self.modes.mouse_motion,
            1004 => self.modes.focus_reporting,
            1005 => self.modes.mouse_utf8,
            1006 => self.modes.mouse_sgr,
            1007 => self.modes.alternate_scroll,
            1036 => self.modes.alt_escape,
            2027 if self.grapheme_supported => self.modes.grapheme_clusters,
            2004 => self.modes.bracketed_paste,
            2026 => self.sync_deadline.is_some(),
            _ => return None,
        })
    }
    fn set_mode(&mut self, mode: u16, ansi: bool, enabled: bool, emit: &mut impl FnMut(Event)) {
        if ansi {
            match mode {
                4 => self.modes.insert = enabled,
                20 => self.modes.newline = enabled,
                _ => {}
            }
            return;
        }
        match mode {
            1 => self.modes.app_cursor = enabled,
            3 => {
                self.screen_mut().region = 0..self.rows();
                self.erase_display(2, emit);
                self.goto(0, 0, false);
            }
            5 => self.modes.reverse_video = enabled,
            6 => {
                self.modes.origin = enabled;
                self.goto(0, 0, true);
            }
            7 => self.modes.wrap = enabled,
            12 => self.modes.cursor_blink = enabled,
            25 => self.modes.cursor_visible = enabled,
            47 | 1047 | 1049 => {
                if self.modes.alternate == enabled {
                    return;
                }
                if enabled && mode == 1049 {
                    self.save_cursor();
                }
                if enabled && mode != 47 {
                    self.alternate.clear();
                    self.saved_state[1] = SavedState::default();
                }
                self.modes.alternate = enabled;
                if !enabled && mode == 1049 {
                    self.restore_cursor();
                }
                emit(Event::Alternate(enabled));
            }
            66 => self.modes.app_keypad = enabled,
            1000 => self.modes.mouse_click = enabled,
            1002 => self.modes.mouse_drag = enabled,
            1003 => self.modes.mouse_motion = enabled,
            1004 => self.modes.focus_reporting = enabled,
            1005 => self.modes.mouse_utf8 = enabled,
            1006 => self.modes.mouse_sgr = enabled,
            1007 => self.modes.alternate_scroll = enabled,
            1036 => self.modes.alt_escape = enabled,
            1048 => {
                if enabled {
                    self.save_cursor();
                } else {
                    self.restore_cursor();
                }
            }
            2004 => self.modes.bracketed_paste = enabled,
            2027 if self.grapheme_supported => self.modes.grapheme_clusters = enabled,
            _ => {}
        }
    }
    fn keyboard(&mut self, c: &Csi, emit: &mut impl FnMut(Event)) {
        let flags = (c.value(0, 0) & 31) as u8;
        match c.prefix {
            Some(b'?') => emit(Event::Reply(
                format!("\x1b[?{}u", self.keyboard_flags()).into_bytes(),
            )),
            Some(b'>') => {
                let screen = self.screen_mut();
                if screen.keyboard_stack.len() == 16 {
                    screen.keyboard_stack.remove(0);
                }
                screen.keyboard_stack.push(screen.keyboard_flags);
                screen.keyboard_flags = flags;
            }
            Some(b'<') => {
                for _ in 0..c.count(0).min(17) {
                    let screen = self.screen_mut();
                    screen.keyboard_flags = screen.keyboard_stack.pop().unwrap_or(0);
                }
            }
            Some(b'=') => {
                let screen = self.screen_mut();
                match c.value(1, 1) {
                    1 => screen.keyboard_flags = flags,
                    2 => screen.keyboard_flags |= flags,
                    3 => screen.keyboard_flags &= !flags,
                    _ => {}
                }
            }
            _ => {}
        }
    }
    fn sgr(&mut self, params: &[Vec<Option<u16>>]) {
        if params.is_empty() {
            self.style = Style::default();
            return;
        }
        let mut index = 0;
        while index < params.len() {
            let part = &params[index];
            let value = part.first().copied().flatten().unwrap_or(0);
            match value {
                0 => self.style = Style::default(),
                1 => self.style.attrs |= cell::BOLD,
                2 => self.style.attrs |= cell::FAINT,
                3 => self.style.attrs |= cell::ITALIC,
                4 => {
                    self.style.underline = part.get(1).copied().flatten().unwrap_or(1).min(5) as u8
                }
                5 | 6 => self.style.attrs |= cell::BLINK,
                7 => self.style.attrs |= cell::INVERSE,
                8 => self.style.attrs |= cell::INVISIBLE,
                9 => self.style.attrs |= cell::STRIKE,
                21 => self.style.underline = 2,
                22 => self.style.attrs &= !(cell::BOLD | cell::FAINT),
                23 => self.style.attrs &= !cell::ITALIC,
                24 => self.style.underline = 0,
                25 => self.style.attrs &= !cell::BLINK,
                27 => self.style.attrs &= !cell::INVERSE,
                28 => self.style.attrs &= !cell::INVISIBLE,
                29 => self.style.attrs &= !cell::STRIKE,
                30..=37 => self.style.fg = Color::Indexed((value - 30) as u8),
                40..=47 => self.style.bg = Color::Indexed((value - 40) as u8),
                90..=97 => self.style.fg = Color::Indexed((value - 90 + 8) as u8),
                100..=107 => self.style.bg = Color::Indexed((value - 100 + 8) as u8),
                39 => self.style.fg = Color::Foreground,
                49 => self.style.bg = Color::Background,
                59 => self.style.underline_color = None,
                38 | 48 | 58 => {
                    let mut color = None;
                    if part.len() > 1 {
                        if part.get(1) == Some(&Some(5)) {
                            color = part
                                .get(2)
                                .copied()
                                .flatten()
                                .filter(|n| *n < 256)
                                .map(|n| Color::Indexed(n as u8));
                        } else if part.get(1) == Some(&Some(2)) {
                            let start = if part.len() >= 6 { 3 } else { 2 };
                            color = parse_channels(&part[start..]);
                        }
                    } else if let Some(kind) = params
                        .get(index + 1)
                        .and_then(|p| p.first())
                        .copied()
                        .flatten()
                    {
                        if kind == 5 {
                            color = params
                                .get(index + 2)
                                .and_then(|p| p.first())
                                .copied()
                                .flatten()
                                .filter(|n| *n < 256)
                                .map(|n| Color::Indexed(n as u8));
                            index = (index + 2).min(params.len());
                        } else if kind == 2 {
                            let channels: [Option<u16>; 3] = std::array::from_fn(|offset| {
                                params.get(index + 2 + offset).and_then(|p| p.first()).copied().flatten()
                            });
                            color = parse_channels(&channels);
                            index = (index + 4).min(params.len());
                        }
                    }
                    if let Some(color) = color {
                        match value {
                            38 => self.style.fg = color,
                            48 => self.style.bg = color,
                            _ => self.style.underline_color = Some(color),
                        }
                    }
                }
                _ => {}
            }
            index += 1;
        }
    }
    fn osc(&mut self, payload: &[u8], terminator: Terminator, emit: &mut impl FnMut(Event)) {
        let split = payload
            .iter()
            .position(|&b| b == b';')
            .unwrap_or(payload.len());
        let number = std::str::from_utf8(&payload[..split])
            .ok()
            .and_then(|s| s.parse::<u16>().ok());
        let body = payload.get(split + 1..).unwrap_or_default();
        let end = if terminator == Terminator::Bell {
            "\x07"
        } else {
            "\x1b\\"
        };
        match number {
            Some(0 | 2) => {
                if body.len() > self.title_max_bytes {
                    return;
                }
                self.title = String::from_utf8_lossy(body)
                    .chars()
                    .filter(|c| !c.is_control())
                    .take(self.title_max_chars)
                    .collect();
                emit(Event::Title(self.title.clone()));
            }
            Some(8) => {
                if let Some(split) = body.iter().position(|&b| b == b';') {
                    let uri = &body[split + 1..];
                    let uri = std::str::from_utf8(uri).ok().filter(|s| {
                        !s.is_empty() && s.len() <= 2048 && !s.chars().any(char::is_control)
                    });
                    if let Some(uri) = uri {
                        self.link_id = self.link_id.wrapping_add(1).max(1);
                        self.link = Some(Arc::new(Link { id: self.link_id, uri: uri.into() }));
                    } else {
                        self.link = None;
                    }
                }
            }
            Some(52) => {
                if let Some(split) = body.iter().position(|&b| b == b';') {
                    let clipboard = std::str::from_utf8(&body[..split]).unwrap_or("c");
                    let data = &body[split + 1..];
                    if data == b"?" {
                        emit(Event::Reply(
                            format!("\x1b]52;{clipboard};{end}").into_bytes(),
                        ));
                    } else if data.len() <= 87384
                        && let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data)
                        && bytes.len() <= 65536
                        && let Ok(text) = String::from_utf8(bytes)
                    {
                        emit(Event::Clipboard(text));
                    }
                }
            }
            Some(4) => {
                let text = String::from_utf8_lossy(body);
                let mut parts = text.split(';');
                while let (Some(index), Some(color)) = (parts.next(), parts.next()) {
                    if let Ok(index @ 0..=255) = index.parse::<u8>() {
                        if color == "?" {
                            self.color_reply(4, Color::Indexed(index), Some(index), end, emit);
                        } else if let Some(rgb) = parse_color(color) {
                            self.palette.set(usize::from(index), Some(rgb));
                        }
                    }
                }
            }
            Some(10..=12) => {
                for (code, color) in
                    (number.unwrap()..).zip(String::from_utf8_lossy(body).split(';'))
                {
                    if code > 12 {
                        break;
                    }
                    let role = if code == 11 {
                        Color::Background
                    } else {
                        Color::Foreground
                    };
                    if color == "?" {
                        self.color_reply(code, role, None, end, emit);
                    } else if let Some(rgb) = parse_color(color) {
                        self.palette.set(
                            match code {
                                11 => 257,
                                12 => 258,
                                _ => 256,
                            },
                            Some(rgb),
                        );
                    }
                }
            }
            Some(104) => {
                if body.is_empty() {
                    for index in 0..256 {
                        self.palette.set(index, None);
                    }
                } else {
                    for part in String::from_utf8_lossy(body).split(';') {
                        if let Ok(index @ 0..=255) = part.parse::<usize>() {
                            self.palette.set(index, None);
                        }
                    }
                }
            }
            Some(110) => self.palette.set(256, None),
            Some(111) => self.palette.set(257, None),
            Some(112) => self.palette.set(258, None),
            _ => emit(Event::Osc(payload.to_vec())),
        }
    }
    fn color_reply(
        &self,
        code: u16,
        color: Color,
        index: Option<u8>,
        end: &str,
        emit: &mut impl FnMut(Event),
    ) {
        let rgb = if code == 12 {
            self.palette
                .cursor()
                .unwrap_or_else(|| self.palette.resolve(Color::Foreground))
        } else {
            self.palette.resolve(color)
        };
        let prefix = index.map_or(String::new(), |i| format!("{i};"));
        emit(Event::Reply(
            format!(
                "\x1b]{code};{prefix}rgb:{:04x}/{:04x}/{:04x}{end}",
                (rgb >> 16 & 255) * 257,
                (rgb >> 8 & 255) * 257,
                (rgb & 255) * 257
            )
            .into_bytes(),
        ));
    }
    fn sgr_report(&self) -> String {
        let mut parts = vec!["0".to_string()];
        for (flag, code) in [
            (cell::BOLD, 1),
            (cell::FAINT, 2),
            (cell::ITALIC, 3),
            (cell::BLINK, 5),
            (cell::INVERSE, 7),
            (cell::INVISIBLE, 8),
            (cell::STRIKE, 9),
        ] {
            if self.style.attrs & flag != 0 {
                parts.push(code.to_string());
            }
        }
        if self.style.underline != 0 {
            parts.push(format!("4:{}", self.style.underline));
        }
        for (color, selector) in [
            (Some(self.style.fg), 38),
            (Some(self.style.bg), 48),
            (self.style.underline_color, 58),
        ] {
            match color {
                Some(Color::Indexed(index)) => parts.push(format!("{selector};5;{index}")),
                Some(Color::Rgb(rgb)) => parts.push(format!(
                    "{selector};2;{};{};{}",
                    rgb[0], rgb[1], rgb[2]
                )),
                _ => {}
            }
        }
        format!("{}m", parts.join(";"))
    }
    fn dcs(&mut self, payload: Vec<u8>, emit: &mut impl FnMut(Event)) {
        if payload.starts_with(b"$q") {
            let query = &payload[2..];
            let answer = match query {
                b"m" => Some(self.sgr_report()),
                b"r" => Some(format!(
                    "{};{}r",
                    self.screen().region.start + 1,
                    self.screen().region.end
                )),
                b" q" => Some(format!("{} q", self.modes.cursor_shape)),
                _ => None,
            };
            emit(Event::Reply(
                match answer {
                    Some(value) => format!("\x1bP1$r{value}\x1b\\"),
                    None => "\x1bP0$r\x1b\\".into(),
                }
                .into_bytes(),
            ));
        } else {
            emit(Event::Dcs(payload));
        }
    }
    pub fn resize(
        &mut self,
        cols: usize,
        rows: usize,
        mut emit: impl FnMut(Event),
    ) -> Result<(), &'static str> {
        Self::validate_size(cols, rows)?;
        self.grapheme_target = None;
        if (cols, rows) == (self.cols(), self.rows()) {
            return Ok(());
        }
        let delta = self.main.resize(cols, rows, true);
        let alternate_delta = self.alternate.resize(cols, rows, false);
        emit(Event::Resize {
            history_delta: delta,
            history: self.main.history.len(),
            alternate_delta,
            rows,
        });
        self.revision = self.revision.wrapping_add(1);
        Ok(())
    }
    fn reset(&mut self, emit: &mut impl FnMut(Event)) {
        let cols = self.cols();
        let rows = self.rows();
        // RIS clears both screens, but keeps configured history capacity.
        self.main.clear_history();
        for row in 0..rows {
            self.main.rows[row].reset_cells(Color::Background);
            self.main.rows[row].wrapped = false;
            self.main.rows[row].generation = self.main.rows[row].generation.wrapping_add(1);
            self.main.rows[row].mark_blank(Color::Background);
        }
        self.main.cursor = Cursor::default();
        self.main.saved_cursor = Cursor::default();
        self.main.region = 0..rows;
        self.main.keyboard_stack.clear();
        self.main.keyboard_flags = 0;
        self.main.selection = None;
        self.main.tabs = (0..cols).map(|col| col != 0 && col % 8 == 0).collect();
        self.alternate.clear();
        self.modes = Modes::default();
        self.style = Style::default();
        self.palette.reset();
        self.link = None;
        self.modes.grapheme_clusters = self.grapheme_supported;
        self.grapheme_target = None;
        self.charsets = [false; 4];
        self.charset = 0;
        self.single_shift = None;
        self.title.clear();
        self.title_stack.clear();
        self.last_printed = None;
        self.saved_state = [SavedState::default(); 2];
        emit(Event::Reset);
        emit(Event::Title(String::new()));
    }
}

fn parse_channels(parts: &[Option<u16>]) -> Option<Color> {
    let [Some(r), Some(g), Some(b), ..] = parts else {
        return None;
    };
    if *r > 255 || *g > 255 || *b > 255 {
        return None;
    }
    Some(Color::rgb(*r as u8, *g as u8, *b as u8))
}
fn parse_color(text: &str) -> Option<u32> {
    if let Some(hex) = text.strip_prefix('#') {
        if hex.len() == 6 {
            return u32::from_str_radix(hex, 16).ok();
        }
        if hex.len() == 3 {
            let n = u16::from_str_radix(hex, 16).ok()?;
            return Some(
                ((u32::from((n >> 8) & 15) * 17) << 16)
                    | ((u32::from((n >> 4) & 15) * 17) << 8)
                    | (u32::from(n & 15) * 17),
            );
        }
    }
    let mut channels = text.strip_prefix("rgb:")?.split('/');
    let mut rgb = 0;
    for _ in 0..3 {
        let part = channels.next()?;
        if part.is_empty() || part.len() > 4 {
            return None;
        }
        let n = u32::from_str_radix(part, 16).ok()?;
        rgb = (rgb << 8) | (n * 255 / ((1u32 << (part.len() * 4)) - 1));
    }
    if channels.next().is_some() {
        return None;
    }
    Some(rgb)
}
fn dec_graphic(ch: char) -> char {
    match ch {
        '`' => '◆',
        'a' => '▒',
        'f' => '°',
        'g' => '±',
        'j' => '┘',
        'k' => '┐',
        'l' => '┌',
        'm' => '└',
        'n' => '┼',
        'o' => '⎺',
        'p' => '⎻',
        'q' => '─',
        'r' => '⎼',
        's' => '⎽',
        't' => '├',
        'u' => '┤',
        'v' => '┴',
        'w' => '┬',
        'x' => '│',
        'y' => '≤',
        'z' => '≥',
        '{' => 'π',
        '|' => '≠',
        '}' => '£',
        '~' => '·',
        _ => ch,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn feed(term: &mut Terminal, bytes: &[u8]) -> Vec<Event> {
        let mut events = Vec::new();
        term.feed(bytes, 0, |e| events.push(e));
        events
    }
    // Compare all protocol and cell state, excluding only reset-range certificates
    // and retained parameter allocations, which may differ between fast/scalar paths.
    fn state(term: &Terminal) -> String {
        format!("{:?}{:?}{:?}{:?}{:?}{:?}", term.parser,
            term.main.state_for_test(), term.alternate.state_for_test(),
            (&term.modes, &term.palette, term.style, term.cell_pixels, term.revision,
             &term.title, &term.link, term.link_id, &term.title_stack, &term.saved_state),
            (term.charsets, term.charset, term.single_shift, term.last_printed, term.sync_deadline,
             &term.sync_actions, term.sync_bytes, term.grapheme_supported, term.grapheme_target),
            (&term.cluster_scratch, term.preserve_erased_screen, term.title_max_bytes, term.title_max_chars))
    }
    /// The original scalar action path is an independent reference for run writes.
    fn feed_scalar(term: &mut Terminal, bytes: &[u8], now: u64) -> Vec<Event> {
        let mut events = Vec::new();
        term.expire_sync(now, |event| events.push(event));
        let mut parser = std::mem::take(&mut term.parser);
        parser.feed(bytes, |action| term.dispatch(action, now, &mut |event| events.push(event)));
        term.parser = parser;
        if !bytes.is_empty() { term.revision = term.revision.wrapping_add(1); }
        events
    }

    #[test]
    fn ascii_runs_match_scalar_state_and_events_through_modes_and_chunk_boundaries() {
        let inputs = [
            "abcdefghijklmnop ABC 0123456789!~", "\r\nnext line ", "\x1b[2;1Hoverwrite cells",
            "\x1b[1;3;4:3;38;2;17;82;201mstyled text\x1b[0m", "\x1b[?7lright margin writes",
            "\x1b[?7hwrap enabled again", "\x1b[4hinserting text\x1b[4l", "\x1b[2;3r\x1b[3;1Hbottom\n",
            "\x1b[r\x1b[H", "\x1b(0lqqqk\x1b(Bplain", "\x1b)0\x0eqqqx\x0fASCII",
            "\x1b*0\x1bNqsingle shift", "\x1b[?1049halt screen\x1b[?1049lback",
            "\x1b]8;;https://example.test\x1b\\linked text\x1b]8;;\x1b\\unlinked text",
            "中👩\u{200d}💻e\u{301}ASCII", "\u{600}abc1\u{fe0f}\u{20e3}xyz", "\x1b[1;1H中中\x1b[1;2Hwide repair",
            "\x1b[?2026hsynchronized text\x1b[6n", "pending text\x1b[?2026l", "\x1b[5brepeat",
            "\x1b[2J\x1b[Hcleared", "\x1b7saved\x1b8restored", "\x07\x1b[6n", "\x1bcreset",
        ];
        for cols in [1, 2, 9, 80] {
            for history in [0, 10] {
                for graphemes in [false, true] {
                    let mut fast = Terminal::new(cols, 3, history).unwrap();
                    let mut scalar = Terminal::new(cols, 3, history).unwrap();
                    fast.enable_grapheme_support(graphemes);
                    scalar.enable_grapheme_support(graphemes);
                    let mut rng = 42u64;
                    for step in 0..400 {
                        rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1);
                        let text = inputs[(rng >> 32) as usize % inputs.len()].as_bytes();
                        // Includes splits inside UTF-8 and escapes, as well as whole long runs.
                        let chunk_size = [1, 3, 7, text.len()][step % 4];
                        for chunk in text.chunks(chunk_size) {
                            let now = step as u64;
                            let mut events = Vec::new();
                            fast.feed(chunk, now, |event| events.push(event));
                            assert_eq!(events, feed_scalar(&mut scalar, chunk, now));
                            assert_eq!(state(&fast), state(&scalar), "cols={cols}, history={history}, graphemes={graphemes}, step={step}");
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn private_cursor_reports_use_the_same_origin_as_standard_reports() {
        for alternate in [false, true] {
            let mut term = Terminal::new(8, 6, 0).unwrap();
            if alternate { feed(&mut term, b"\x1b[?1049h"); }
            feed(&mut term, b"\x1b[3;6r\x1b[?6h\x1b[2;4H");
            assert_eq!(term.cursor(), Position { row: 3, col: 3 });
            assert_eq!(feed(&mut term, b"\x1b[6n\x1b[?6n"), vec![
                Event::Reply(b"\x1b[2;4R".to_vec()), Event::Reply(b"\x1b[?2;4R".to_vec()),
            ]);
            feed(&mut term, b"\x1b[?6l\x1b[4;4H");
            assert_eq!(feed(&mut term, b"\x1b[6n\x1b[?6n"), vec![
                Event::Reply(b"\x1b[4;4R".to_vec()), Event::Reply(b"\x1b[?4;4R".to_vec()),
            ]);
        }
    }

    #[test]
    fn wide_overwrites_repair_neighbours_outside_the_span_and_keep_generations() {
        for (seed, col, expected) in [
            ("中中", 0, [('界', 2), (' ', 0), ('中', 2), (' ', 0)]),
            ("中中", 1, [(' ', 1), ('界', 2), (' ', 0), (' ', 1)]),
            ("中中", 2, [('中', 2), (' ', 0), ('界', 2), (' ', 0)]),
            ("a中b", 0, [('界', 2), (' ', 0), (' ', 1), ('b', 1)]),
            ("abcd", 1, [('a', 1), ('界', 2), (' ', 0), ('d', 1)]),
        ] {
            let mut term = Terminal::new(4, 1, 0).unwrap();
            feed(&mut term, seed.as_bytes());
            feed(&mut term, format!("\x1b[1;{}H", col + 1).as_bytes());
            let generation = term.screen().rows[0].generation;
            feed(&mut term, "界".as_bytes());
            let row = &term.screen().rows[0];
            assert_eq!(row.generation, generation + 2);
            assert_eq!(row.cells.iter().map(|c| (c.ch, c.width)).collect::<Vec<_>>(), expected);
        }
    }

    #[test]
    fn prefix_resets_match_full_resets_through_edits_backgrounds_history_and_resize() {
        fn assert_screen(a: &Screen, b: &Screen) {
            assert_eq!((a.cursor, a.saved_cursor, a.offset, a.selection),
                       (b.cursor, b.saved_cursor, b.offset, b.selection));
            assert_eq!((&a.region, &a.tabs, a.keyboard_flags, &a.keyboard_stack, a.cols),
                       (&b.region, &b.tabs, b.keyboard_flags, &b.keyboard_stack, b.cols));
            assert_eq!((a.rows.len(), a.history.len(), a.history_bytes_for_test()),
                       (b.rows.len(), b.history.len(), b.history_bytes_for_test()));
            for (a, b) in a.rows.iter().chain(&a.history).zip(b.rows.iter().chain(&b.history)) {
                assert_eq!((a.id, &a.cells, a.wrapped, a.wrap_padding, a.generation),
                           (b.id, &b.cells, b.wrapped, b.wrap_padding, b.generation));
            }
        }
        let inputs = [
            "short\r\n", "          \r\n", "\x1b[1;8H ", "中中😀e\u{301}",
            "\x1b[48;2;1;2;3m\x1b[2K", "\x1b[49m\x1b[2J", "\x1b[31;4m styled ",
            "\x1b[H\x1b[2@", "\x1b[1;2H\x1b[3P", "\x1b[2;1H\x1b[4X", "\x1b[0K\x1b[1K",
            "\x1b[2;3r\x1b[3;1Hscroll\n\x1b[r", "\x1b[2S\x1b[T", "\x1b[L\x1b[M",
            "\x1b]8;;https://example.test\x1b\\linked\x1b]8;;\x1b\\",
            "\x1b[?1049h alternate 中\x1b[?1049l", "\x1b#8", "\x1bc", "\x1b[6n\x07",
            "\x1b[?2026h中 styled\x1b[48:2::7:8:9m \x1b[?2026l",
        ];
        for history in [0, 1, 10] {
            for graphemes in [false, true] {
                let mut fast = Terminal::new(11, 4, history).unwrap();
                let mut full = Terminal::new(11, 4, history).unwrap();
                fast.enable_grapheme_support(graphemes); full.enable_grapheme_support(graphemes);
                let mut rng = 42u64;
                for step in 0..1000 {
                    rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1);
                    let bytes = inputs[(rng >> 32) as usize % inputs.len()].as_bytes();
                    for chunk in bytes.chunks([1, 3, bytes.len()][step % 3]) {
                        full.main.force_full_reset_for_test(); full.alternate.force_full_reset_for_test();
                        assert_eq!(feed(&mut fast, chunk), feed(&mut full, chunk));
                        assert_screen(&fast.main, &full.main); assert_screen(&fast.alternate, &full.alternate);
                        assert_eq!(format!("{:?}", fast.modes), format!("{:?}", full.modes));
                    }
                    if step % 17 == 0 {
                        let cols = [1, 2, 7, 20][step / 17 % 4];
                        let rows = [1, 3, 5][step / 17 % 3];
                        full.main.force_full_reset_for_test(); full.alternate.force_full_reset_for_test();
                        let mut actual = Vec::new(); let mut expected = Vec::new();
                        fast.resize(cols, rows, |e| actual.push(e)).unwrap();
                        full.resize(cols, rows, |e| expected.push(e)).unwrap();
                        assert_eq!(actual, expected);
                        assert_screen(&fast.main, &full.main); assert_screen(&fast.alternate, &full.alternate);
                    }
                }
            }
        }
    }

    #[test]
    fn synchronized_ascii_runs_flush_like_scalar_actions_on_end_and_timeout() {
        let text = format!("{}\x1b[31mstyled\x1b[0m中\x1b[1;1Hwide overwrite\x1b(0qqq\x1b(Bascii\x1b[6n\x07",
                           "ordinary text 0123456789 ".repeat(600));
        for timeout in [false, true] {
            let mut fast = Terminal::new(17, 4, 10).unwrap();
            let mut scalar = Terminal::new(17, 4, 10).unwrap();
            for term in [&mut fast, &mut scalar] {
                term.enable_grapheme_support(true);
                term.feed(b"\x1b[?2026h", 0, |_| panic!("unexpected event"));
                term.feed(text.as_bytes(), 0, |_| panic!("synchronized output escaped"));
                assert!(term.sync_deadline.is_some());
            }
            // Flush the reference strictly through the original scalar apply path.
            scalar.sync_deadline = None; scalar.sync_bytes = 0;
            let mut expected = Vec::new();
            for action in std::mem::take(&mut scalar.sync_actions) {
                scalar.apply(action, &mut |event| expected.push(event));
            }
            scalar.revision = scalar.revision.wrapping_add(1);
            let mut actual = Vec::new();
            if timeout { assert!(fast.expire_sync(200, |event| actual.push(event))); }
            else { fast.feed(b"\x1b[?2026l", 1, |event| actual.push(event)); }
            assert_eq!(actual, expected);
            assert_eq!(state(&fast), state(&scalar));
        }
    }
    #[test]
    fn grapheme_widening_respects_decawm() {
        // With DECAWM off, widening the last-column cell into a two-column
        // grapheme cluster must not wrap or linefeed (print() already clamps).
        let mut term = Terminal::new(4, 2, 10).unwrap();
        term.enable_grapheme_support(true);
        feed(&mut term, "\x1b[?7labc\u{2764}\u{fe0f}".as_bytes());
        assert_eq!(term.cursor().row, 0, "no linefeed with DECAWM off");
        assert_eq!(term.screen().history.len(), 0);
        assert!(!term.screen().rows[0].wrapped);
        assert_eq!(term.screen().rows[0].cells[3].ch, '\u{2764}');
        assert!(term.screen().rows[0].cells[3].combining.contains(&'\u{fe0f}'));
        // With DECAWM on (the default) the cluster still wraps to the next row.
        let mut term = Terminal::new(4, 2, 10).unwrap();
        term.enable_grapheme_support(true);
        feed(&mut term, "abc\u{2764}\u{fe0f}".as_bytes());
        assert_eq!(term.cursor().row, 1, "wrap allowed with DECAWM on");
    }
    #[test]
    fn edits_styles_and_queries_survive_all_chunk_boundaries() {
        let stream = "abc中e\u{301}\x1b[2;3H\x1b[38:2::1:2:3;4:3mX\x1b[6n\x1b[?25l\x1b]8;;https://a.test\x1b\\Z".as_bytes();
        let mut whole = Terminal::new(12, 3, 10).unwrap();
        let expected_events = feed(&mut whole, stream);
        for cut in 0..=stream.len() {
            let mut term = Terminal::new(12, 3, 10).unwrap();
            let mut events = feed(&mut term, &stream[..cut]);
            events.extend(feed(&mut term, &stream[cut..]));
            assert_eq!(events, expected_events, "cut {cut}");
            assert_eq!(term.cursor(), whole.cursor());
            assert!(!term.modes.cursor_visible);
            for row in 0..3 {
                assert_eq!(
                    term.screen().rows[row].cells,
                    whole.screen().rows[row].cells
                );
            }
        }
    }
    #[test]
    fn actual_scroll_events_keep_history_and_region_consistent() {
        let mut term = Terminal::new(5, 3, 2).unwrap();
        let events = feed(&mut term, b"a\r\nb\r\nc\r\nd\r\ne\r\nf");
        assert_eq!(term.screen().history.len(), 2);
        assert_eq!(term.screen().line(-2).unwrap().text().trim_end(), "b");
        assert_eq!(
            events
                .iter()
                .filter(|e| matches!(e, Event::Scroll { .. }))
                .count(),
            3
        );
        let events = feed(&mut term, b"\x1b[2;3r\x1b[3;1H\n");
        assert!(matches!(
            &events[0],
            Event::Scroll {
                top: 1,
                bottom: 3,
                to_history: false,
                ..
            }
        ));
        assert_eq!(term.screen().history.len(), 2);
        assert_eq!(term.screen().rows[0].text().trim_end(), "d");
    }
    #[test]
    fn alternate_restores_main_cursor_and_separate_keyboard_stack() {
        let mut term = Terminal::new(10, 3, 10).unwrap();
        feed(&mut term, b"main\x1b[>5u\x1b[?1049halt\x1b[>8u");
        assert_eq!(term.keyboard_flags(), 8);
        assert_eq!(term.screen().rows[0].text().trim_end(), "alt");
        feed(&mut term, b"\x1b[?1049l");
        assert_eq!(term.keyboard_flags(), 5);
        assert_eq!(term.cursor().col, 4);
        assert_eq!(term.screen().rows[0].text().trim_end(), "main");
    }
    #[test]
    fn synchronized_output_flushes_queries_once_on_host_deadline() {
        let mut term = Terminal::new(10, 3, 10).unwrap();
        assert!(feed(&mut term, b"\x1b[?2026hword\x1b[6n").is_empty());
        assert_eq!(term.screen().rows[0].text().trim_end(), "");
        let mut events = Vec::new();
        assert!(term.expire_sync(151, |e| events.push(e)));
        assert_eq!(events, vec![Event::Reply(b"\x1b[1;5R".to_vec())]);
        assert!(!term.expire_sync(999, |_| panic!("duplicate")));
    }
    #[test]
    fn selection_tracks_rows_and_includes_wide_cells_once() {
        let mut term = Terminal::new(10, 2, 10).unwrap();
        feed(&mut term, "ab中e\u{301}\r\nnext".as_bytes());
        term.screen_mut()
            .select(Position { row: 0, col: 3 }, Position { row: 0, col: 4 });
        assert_eq!(term.screen().selection_text(), "中e\u{301}");
        feed(&mut term, b"\r\nlast");
        assert_eq!(term.screen().selection_text(), "中e\u{301}");
        assert!(term.screen().selected(-1, 2));
    }
    #[test]
    fn resize_reflows_wrapped_text_and_keeps_cursor() {
        let mut term = Terminal::new(6, 3, 100).unwrap();
        feed(&mut term, b"abcdefghijkl");
        term.resize(4, 4, |_| {}).unwrap();
        assert_eq!(term.screen().rows[0].text(), "abcd");
        assert_eq!(term.screen().rows[1].text(), "efgh");
        assert_eq!(term.screen().rows[2].text(), "ijkl");
        assert_eq!(term.cursor(), Position { row: 2, col: 3 });
        assert!(term.screen().cursor.pending_wrap);
        feed(&mut term, b"m");
        assert_eq!(term.screen().rows[3].text(), "m   ");
    }
    #[test]
    fn single_shift_uses_g2_or_g3_for_one_character_and_preserves_gl() {
        for (input, expected) in [
            ("\x1b*0\x1bNqq", "─q      "),
            ("\x1b+0\x1bOxx", "│x      "),
            ("\x1b)0\x0e\x1bNqq", "q─      "),
        ] {
            let mut term = Terminal::new(8, 2, 10).unwrap();
            feed(&mut term, input.as_bytes());
            assert_eq!(term.screen().rows[0].text(), expected);
        }
    }

    #[test]
    fn synchronized_mode_lists_hold_output_until_the_reset_mode_is_processed() {
        let mut term = Terminal::new(8, 2, 10).unwrap();
        term.feed(b"\x1b[?25l\x1b[?2026;25habc\x1b[6n", 10, |_| {
            panic!("synchronized reply escaped early")
        });
        assert!(term.sync_deadline().is_some());
        assert!(!term.modes.cursor_visible);
        assert_eq!(term.screen().rows[0].text(), "        ");
        let mut events = Vec::new();
        term.feed(b"\x1b[?2026;25l", 11, |event| events.push(event));
        assert!(term.sync_deadline().is_none());
        assert!(!term.modes.cursor_visible);
        assert_eq!(term.screen().rows[0].text(), "abc     ");
        assert_eq!(events, vec![Event::Reply(b"\x1b[1;4R".to_vec())]);
        assert!(!term.expire_sync(1000, |_| panic!("reply repeated")));
    }

    #[test]
    fn reflow_preserves_cursor_on_the_trailing_half_of_a_wide_cell() {
        for (input, cols, rows, expected) in [
            ("中abc\x1b[1;2H", 10, 3, Position { row: 0, col: 1 }),
            ("ab中xyz\x1b[1;4H", 3, 4, Position { row: 1, col: 1 }),
        ] {
            let mut term = Terminal::new(8, 3, 10).unwrap();
            feed(&mut term, input.as_bytes());
            term.resize(cols, rows, |_| {}).unwrap();
            assert_eq!(term.cursor(), expected, "{input:?}");
            feed(&mut term, b"Z");
            assert_eq!(term.screen().rows[expected.row].cells[expected.col].ch, 'Z');
        }
    }

    #[test]
    fn resizing_scrolled_history_keeps_the_visible_row() {
        let mut term = Terminal::new(8, 3, 100).unwrap();
        feed(&mut term, b"zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive");
        term.screen_mut().scroll_display(2);
        assert_eq!(
            term.screen().viewport_line(0).unwrap().text().trim_end(),
            "one"
        );
        for (cols, rows) in [(8, 4), (10, 3), (8, 2)] {
            term.resize(cols, rows, |_| {}).unwrap();
            assert_eq!(
                term.screen().viewport_line(0).unwrap().text().trim_end(),
                "one"
            );
        }
    }

    #[test]
    fn native_selection_preserves_soft_wrap_spaces_and_omits_wide_padding() {
        for (input, end, expected) in [
            ("ab  cd", Position { row: 1, col: 1 }, "ab  cd"),
            ("abc中", Position { row: 1, col: 1 }, "abc中"),
        ] {
            let mut term = Terminal::new(4, 3, 10).unwrap();
            feed(&mut term, input.as_bytes());
            term.screen_mut().select(Position { row: 0, col: 0 }, end);
            assert_eq!(term.screen().selection_text(), expected);
        }
    }

    #[test]
    fn cursor_save_restores_charset_designation_and_locking_selection() {
        for (input, expected) in [
            ("\x1b(0\x1b7\x1b(B\x1b8q", "─       "),
            ("\x1b)0\x0e\x1b7\x0f\x1b8q", "─       "),
            ("\x1b)0\x0e\x1b[?1049h\x0f\x1b[?1049lq", "─       "),
        ] {
            let mut term = Terminal::new(8, 3, 10).unwrap();
            feed(&mut term, input.as_bytes());
            assert_eq!(term.screen().rows[0].text(), expected);
        }
    }

    #[test]
    fn zero_bottom_margin_resets_the_full_screen_region() {
        let mut term = Terminal::new(8, 4, 10).unwrap();
        feed(&mut term, b"\x1b[2;3r\x1b[0;0r");
        assert_eq!(term.screen().region, 0..4);
        feed(&mut term, b"\x1b[2;0r");
        assert_eq!(term.screen().region, 1..4);
        feed(&mut term, b"\x1b[3;3r");
        assert_eq!(term.screen().region, 1..4);
    }

    #[test]
    fn resizing_reflows_the_saved_cursor_and_its_delayed_wrap() {
        let mut term = Terminal::new(4, 3, 10).unwrap();
        feed(&mut term, b"abcd\x1b7");
        term.resize(8, 3, |_| {}).unwrap();
        feed(&mut term, b"\x1b8e");
        assert_eq!(term.screen().rows[0].text(), "abcde   ");
        assert_eq!(term.cursor(), Position { row: 0, col: 5 });
        feed(&mut term, b"fghij\x1b7");
        term.resize(4, 4, |_| {}).unwrap();
        feed(&mut term, b"\x1b8k");
        assert_eq!(term.screen().rows[2].text(), "ijk ");
    }

    #[test]
    fn resizing_reflows_the_top_visible_wrapped_history_row() {
        let mut term = Terminal::new(4, 2, 10).unwrap();
        feed(&mut term, b"abcdefghijklmnop");
        term.screen_mut().scroll_display(1);
        assert_eq!(term.screen().viewport_line(0).unwrap().text(), "efgh");
        term.resize(2, 2, |_| {}).unwrap();
        assert_eq!(term.screen().viewport_line(0).unwrap().text(), "ef");
        term.resize(8, 2, |_| {}).unwrap();
        assert_eq!(term.screen().viewport_line(0).unwrap().text(), "abcdefgh");
    }

    #[test]
    fn cursor_save_restores_character_sets_and_pending_single_shift() {
        let mut term = Terminal::new(8, 2, 10).unwrap();
        feed(&mut term, b"\x1b)0\x0e\x1b*0\x1bN\x1b7\x1b(B\x1b)B\x1b*B\x0fq\x1b8qq");
        assert_eq!(term.screen().rows[0].text(), "──      ");
    }

    #[test]
    fn cursor_save_restores_autowrap_mode() {
        let mut term = Terminal::new(4, 2, 10).unwrap();
        feed(&mut term, b"\x1b7\x1b[?7l\x1b8abcde");
        assert_eq!(term.screen().rows[0].text(), "abcd");
        assert_eq!(term.screen().rows[1].text(), "e   ");
    }

    #[test]
    fn scroll_margins_treat_zero_as_default_and_ignore_equal_bounds() {
        let mut term = Terminal::new(8, 4, 10).unwrap();
        feed(&mut term, b"\x1b[2;3r\x1b[0;0r");
        assert_eq!(term.screen().region, 0..4);
        feed(&mut term, b"\x1b[2;4r\x1b[3;5H\x1b[2;2r");
        assert_eq!(term.screen().region, 1..4);
        assert_eq!(term.cursor(), Position { row: 2, col: 4 });
    }

    #[test]
    fn unsafe_or_unbounded_state_is_rejected() {
        assert!(Terminal::new(4096, 4096, 1).is_err());
        let mut term = Terminal::new(5, 2, 1).unwrap();
        feed(&mut term, format!("a{}", "\u{301}".repeat(1000)).as_bytes());
        assert_eq!(
            term.screen().rows[0].cells[0].combining.len(),
            cell::MAX_COMBINING
        );
        let events = feed(&mut term, b"\x1b]52;c;?\x07");
        assert_eq!(events, vec![Event::Reply(b"\x1b]52;c;\x07".to_vec())]);
        let events = feed(&mut term, b"\x1b]52;c;aGVsbG8=\x07");
        assert_eq!(events, vec![Event::Clipboard("hello".into())]);
    }

    #[test]
    fn line_and_character_edits_reset_the_cursor_like_xterm() {
        let mut term = Terminal::new(5, 3, 10).unwrap();
        // IL and DL return to the left margin and drop a pending wrap.
        feed(&mut term, b"abcde[L");
        assert_eq!(term.cursor(), Position { row: 0, col: 0 });
        assert!(!term.screen().cursor.pending_wrap);
        feed(&mut term, b"[2;4H[M");
        assert_eq!(term.cursor(), Position { row: 1, col: 0 });
        // Edits at the last column keep the next print on the same row.
        for edit in [&b"[@"[..], b"[P", b"[X", b"[K", b"[J"] {
            let mut term = Terminal::new(5, 3, 10).unwrap();
            feed(&mut term, b"abcde");
            assert!(term.screen().cursor.pending_wrap);
            feed(&mut term, edit);
            feed(&mut term, b"Z");
            assert_eq!(term.cursor().row, 0, "{edit:?}");
            assert_eq!(term.screen().rows[0].cells[4].ch, 'Z', "{edit:?}");
        }
    }

    #[test]
    fn shrinking_rows_keeps_the_cursor_on_its_line() {
        let mut term = Terminal::new(5, 5, 10).unwrap();
        feed(&mut term, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;1H");
        term.resize(5, 3, |_| {}).unwrap();
        let pos = term.cursor();
        assert_eq!(term.screen().rows[pos.row].cells[0].ch, '2');
        feed(&mut term, b"X");
        assert_eq!(term.screen().rows[pos.row].cells[0].ch, 'X');
        assert!(term.screen().rows.iter().any(|row| row.cells[0].ch == '3'));
    }

    #[test]
    fn blank_fill_skip_still_clears_rows_written_after_a_blank() {
        let mut term = Terminal::new(20, 4, 0).unwrap();
        feed(&mut term, b"\x1b[2J");
        feed(&mut term, b"HELLO");
        feed(&mut term, b"\x1b[2J");
        assert!(
            term.screen().rows.iter().all(|row| row.used() == 0),
            "a write after a blank must invalidate the skip and be erased"
        );
    }

    #[test]
    fn full_row_erase_refills_when_the_bce_background_changes() {
        let mut term = Terminal::new(8, 3, 0).unwrap();
        feed(&mut term, b"\x1b[41m\x1b[2J");
        assert!(term.screen().rows.iter().all(|row| row
            .cells
            .iter()
            .all(|c| c.style.bg == Color::Indexed(1))));
        // A different BCE colour must refill, not reuse the red blank marker.
        feed(&mut term, b"\x1b[44m\x1b[2J");
        assert!(
            term.screen().rows.iter().all(|row| row
                .cells
                .iter()
                .all(|c| c.style.bg == Color::Indexed(4))),
            "erase with a new background must not skip the fill"
        );
    }

    #[test]
    fn resize_invalidates_blank_markers_before_a_later_erase() {
        let mut term = Terminal::new(10, 4, 0).unwrap();
        // Disable preserve-erased-screen so ED2 erases rows in place instead of
        // scrolling content to history first (which would mask a stale blank marker).
        term.preserve_erased_screen = false;
        feed(&mut term, b"ABCDEFGHIJKLMNOPQRST");
        // Reflow rebuilds rows via blank() and moves cells in without a generation
        // bump; a stale blank marker would let ED2 skip them and leave content.
        term.resize(5, 4, |_| {}).unwrap();
        feed(&mut term, b"\x1b[2J");
        assert!(
            term.screen().rows.iter().all(|row| row.used() == 0),
            "reflowed content must be erasable after resize"
        );
    }

    #[test]
    fn resize_then_write_then_erase_does_not_skip_the_written_row() {
        let mut term = Terminal::new(10, 4, 0).unwrap();
        term.preserve_erased_screen = false;
        feed(&mut term, b"ABCDEFGHIJKLMNOPQRST");
        term.resize(5, 4, |_| {}).unwrap();
        // A single width-1 write bumps generation by exactly one. A `+1` blank
        // invalidation would re-alias the marker here and let ED2 skip the row,
        // leaving the 'Z' behind; a past-generation invalidation must not.
        feed(&mut term, b"\x1b[HZ");
        feed(&mut term, b"\x1b[2J");
        assert!(
            term.screen().rows.iter().all(|row| row.used() == 0),
            "a row written after resize must not be skipped by a later erase"
        );
    }

    #[test]
    fn alternate_screen_cycles_leave_no_stale_content() {
        let mut term = Terminal::new(20, 4, 100).unwrap();
        for _ in 0..3 {
            feed(&mut term, b"\x1b[?1049h\x1b[H\x1b[2JSTALE\x1b[?1049l");
        }
        feed(&mut term, b"\x1b[?1049h\x1b[H\x1b[2J");
        assert!(term.modes.alternate);
        assert!(
            term.screen().rows.iter().all(|row| row.used() == 0),
            "entering the alternate screen and clearing must leave it fully blank"
        );
    }

    #[test]
    fn decaln_fill_then_erase_clears_every_row() {
        let mut term = Terminal::new(8, 3, 0).unwrap();
        term.preserve_erased_screen = false;
        // DECALN fills the screen with 'E' and bumps generation; the blank marker
        // must be invalidated so a following ED2 refills instead of skipping.
        feed(&mut term, b"\x1b#8");
        assert!(term.screen().rows.iter().all(|row| row.cells.iter().all(|c| c.ch == 'E')));
        feed(&mut term, b"\x1b[2J");
        assert!(
            term.screen().rows.iter().all(|row| row.used() == 0),
            "DECALN content must be erasable; the fill bump invalidates the blank marker"
        );
    }

    #[test]
    fn plain_print_over_a_wide_half_still_repairs_the_neighbour() {
        // Overwriting the spacer tail must blank the wide lead (fast path must not fire).
        let mut term = Terminal::new(6, 2, 0).unwrap();
        feed(&mut term, "中".as_bytes());
        assert_eq!(term.screen().rows[0].cells[0].width, 2);
        assert_eq!(term.screen().rows[0].cells[1].width, 0);
        feed(&mut term, b"\x1b[1;2HX");
        assert_eq!(term.screen().rows[0].cells[1].ch, 'X');
        assert_eq!(term.screen().rows[0].cells[0].ch, ' ', "wide lead blanked when its tail is overwritten");
        // Overwriting the wide lead must blank the spacer tail.
        let mut term = Terminal::new(6, 2, 0).unwrap();
        feed(&mut term, "中".as_bytes());
        feed(&mut term, b"\x1b[1;1HY");
        assert_eq!(term.screen().rows[0].cells[0].ch, 'Y');
        assert_eq!(term.screen().rows[0].cells[1].ch, ' ', "spacer tail blanked when its lead is overwritten");
    }

    #[test]
    fn plain_overwrite_uses_fast_path_and_bumps_generation() {
        let mut term = Terminal::new(6, 2, 0).unwrap();
        feed(&mut term, b"ABC");
        let gen_before = term.screen().rows[0].generation;
        feed(&mut term, b"\x1b[1;2HX");
        assert_eq!(term.screen().rows[0].cells[0].ch, 'A');
        assert_eq!(term.screen().rows[0].cells[1].ch, 'X');
        assert_eq!(term.screen().rows[0].cells[2].ch, 'C');
        assert!(term.screen().rows[0].generation > gen_before, "fast path must bump generation");
    }

    #[test]
    fn fast_path_print_invalidates_the_blank_marker() {
        let mut term = Terminal::new(6, 2, 0).unwrap();
        term.preserve_erased_screen = false;
        feed(&mut term, b"\x1b[2J");
        feed(&mut term, b"Z");
        feed(&mut term, b"\x1b[2J");
        assert!(
            term.screen().rows.iter().all(|row| row.used() == 0),
            "a fast-path write must invalidate the blank marker so ED2 clears it"
        );
    }

    fn history_base(term: &Terminal) -> usize {
        term.screen().history.len() * term.cols() * std::mem::size_of::<Cell>()
    }

    #[test]
    fn heap_free_history_rows_are_counted_as_base_only() {
        let mut term = Terminal::new(10, 2, 100).unwrap();
        feed(&mut term, b"abc\r\ndef\r\nghi\r\njkl\r\n");
        assert!(!term.screen().history.is_empty());
        assert_eq!(
            term.screen().history_bytes_for_test(),
            history_base(&term),
            "plain rows must skip the heap scan and count base bytes only"
        );
    }

    #[test]
    fn combining_rows_never_undercount_the_history_budget() {
        // Grapheme mode routes combining through join_grapheme.
        let mut term = Terminal::new(10, 2, 100).unwrap();
        term.enable_grapheme_support(true);
        feed(&mut term, "a\u{0301}\r\nb\u{0301}\r\nc\u{0301}\r\nd\u{0301}\r\n".as_bytes());
        assert!(!term.screen().history.is_empty());
        assert!(
            term.screen().history_bytes_for_test() > history_base(&term),
            "combining heap must be counted (join_grapheme path)"
        );
        // Without grapheme mode combining goes through the width-0 print path.
        let mut term = Terminal::new(10, 2, 100).unwrap();
        feed(&mut term, "a\u{0301}\r\nb\u{0301}\r\nc\u{0301}\r\nd\u{0301}\r\n".as_bytes());
        assert!(!term.screen().history.is_empty());
        assert!(
            term.screen().history_bytes_for_test() > history_base(&term),
            "combining heap must be counted (width-0 print path)"
        );
    }

    #[test]
    fn hyperlink_rows_never_undercount_the_history_budget() {
        let mut term = Terminal::new(10, 2, 100).unwrap();
        feed(&mut term, b"\x1b]8;;https://example.com\x1b\\abc\x1b]8;;\x1b\\\r\n");
        feed(&mut term, b"x\r\ny\r\nz\r\n");
        assert!(!term.screen().history.is_empty());
        assert!(
            term.screen().history_bytes_for_test() > history_base(&term),
            "hyperlink heap must be counted (print link path)"
        );
    }

    #[test]
    fn resize_keeps_heap_rows_counted_in_history() {
        let mut term = Terminal::new(10, 2, 100).unwrap();
        term.enable_grapheme_support(true);
        feed(&mut term, "a\u{0301}b\u{0301}c\u{0301}\r\n".as_bytes());
        term.resize(5, 2, |_| {}).unwrap();
        feed(&mut term, b"x\r\ny\r\nz\r\n");
        assert!(!term.screen().history.is_empty());
        assert!(
            term.screen().history_bytes_for_test() > history_base(&term),
            "resize must not let reflowed heap rows under-count"
        );
    }

    #[test]
    fn erased_heap_row_scrolls_into_history_as_base_only() {
        let mut term = Terminal::new(10, 2, 100).unwrap();
        term.preserve_erased_screen = false;
        feed(&mut term, b"\x1b]8;;https://example.com\x1b\\abc\x1b]8;;\x1b\\\r\n");
        feed(&mut term, b"\x1b[2J");
        feed(&mut term, b"x\r\ny\r\nz\r\n");
        assert!(!term.screen().history.is_empty());
        assert_eq!(
            term.screen().history_bytes_for_test(),
            history_base(&term),
            "a fully-erased heap row must count base-only once mark_blank clears the flag"
        );
    }
}
