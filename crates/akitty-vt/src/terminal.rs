//! Terminal behavior implemented against public terminal protocol specifications.
//!
//! Every input chunk is applied in order. Content movement events describe actual
//! grid mutations, so consumers never need to simulate scrolling a second time.

use crate::cell::{self, Cell, Color, Palette, Style};
use crate::parser::{Action, Csi, Parser, StringKind, Terminator};
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
    link: Option<Arc<str>>,
    link_id: u32,
    title_stack: Vec<String>,
    saved_style: [Style; 2],
    saved_origin: [bool; 2],
    charsets: [bool; 4],
    charset: usize,
    last_printed: Option<char>,
    sync_deadline: Option<u64>,
    sync_actions: Vec<Action>,
    sync_bytes: usize,
    grapheme_supported: bool,
    grapheme_target: Option<Position>,
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
            saved_style: [Style::default(); 2],
            saved_origin: [false; 2],
            charsets: [false; 4],
            charset: 0,
            last_printed: None,
            sync_deadline: None,
            sync_actions: Vec::new(),
            sync_bytes: 0,
            grapheme_supported: false,
            grapheme_target: None,
            preserve_erased_screen: true,
            title_max_bytes: crate::parser::MAX_STRING_BYTES,
            title_max_chars: 128,
        })
    }
    pub fn screen(&self) -> &Screen {
        if self.modes.alternate {
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
        parser.feed(bytes, |action| self.dispatch(action, now_ms, &mut emit));
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
        for action in std::mem::take(&mut self.sync_actions) {
            self.apply(action, emit);
        }
    }
    fn dispatch(&mut self, action: Action, now: u64, emit: &mut impl FnMut(Event)) {
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
        self.screen_mut().rows[row].generation = self.screen().rows[row].generation.wrapping_add(1);
        let cells = &mut self.screen_mut().rows[row].cells;
        if cells[col].width == 0 && col > 0 {
            cells[col - 1] = Cell::blank(bg);
        }
        if cells[col].width == 2 && col + 1 < cols {
            cells[col + 1] = Cell::blank(bg);
        }
        cells[col] = Cell::blank(bg);
    }
    fn print(&mut self, mut ch: char, emit: &mut impl FnMut(Event)) {
        if self.charsets[self.charset] {
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
                row.cells[col].combining.push(ch);
                row.cells[col].written = true;
                row.generation = row.generation.wrapping_add(1);
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
        self.clear_wide_at(pos.row, pos.col, self.style.bg);
        if width == 2 {
            self.clear_wide_at(pos.row, pos.col + 1, self.style.bg);
        }
        let style = self.style;
        let link = self.link.clone();
        let link_id = if link.is_some() { self.link_id } else { 0 };
        self.screen_mut().rows[pos.row].cells[pos.col] = Cell {
            ch,
            width: width as u8,
            style,
            link: link.clone(),
            link_id,
            combining: Vec::new(),
            written: true,
        };
        if width == 2 {
            self.screen_mut().rows[pos.row].cells[pos.col + 1] = Cell {
                width: 0,
                style,
                link,
                link_id,
                ..Cell::default()
            };
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
        let previous = &self.screen().rows[position.row].cells[position.col];
        if ch.is_ascii() && previous.ch.is_ascii() && previous.combining.is_empty() {
            return false;
        }
        let mut cluster = previous.text();
        cluster.push(ch);
        if cluster.graphemes(true).nth(1).is_some() {
            return false;
        }
        if previous.combining.len() >= cell::MAX_COMBINING {
            return true;
        }
        let mut cell = previous.clone();
        let old_width = usize::from(cell.width);
        let width = cluster.width().clamp(1, 2).min(self.cols());
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
            link_id: cell.link_id,
            ..Cell::default()
        };
        let row = &mut self.screen_mut().rows[position.row];
        row.cells[position.col] = cell;
        if width == 2 {
            row.cells[position.col + 1] = trail;
        }
        row.generation = row.generation.wrapping_add(1);
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
        self.saved_style[usize::from(self.modes.alternate)] = self.style;
        self.saved_origin[usize::from(self.modes.alternate)] = self.modes.origin;
    }
    fn restore_cursor(&mut self) {
        self.screen_mut().cursor = self.screen().saved_cursor;
        self.style = self.saved_style[usize::from(self.modes.alternate)];
        self.modes.origin = self.saved_origin[usize::from(self.modes.alternate)];
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
                row.generation = row.generation.wrapping_add(1);
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
            b'N' => self.charset = 2,
            b'O' => self.charset = 3,
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
            self.clear_wide_at(row, start, bg);
            if end < cols && self.screen().rows[row].cells[end].width == 0 {
                self.clear_wide_at(row, end, bg);
            }
            self.screen_mut().rows[row].cells[start..end].fill(Cell::blank(bg));
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
        self.screen_mut().rows[pos.row].generation =
            self.screen().rows[pos.row].generation.wrapping_add(1);
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
            (None, b'J') => self.erase_display(c.value(0, 0), emit),
            (None, b'K') => match c.value(0, 0) {
                0 => self.erase(pos.row, pos.col..self.cols()),
                1 => self.erase(pos.row, 0..pos.col + 1),
                2 => self.erase(pos.row, 0..self.cols()),
                _ => {}
            },
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
                let end = usize::from(c.value(1, self.rows() as u16)).min(self.rows());
                if start < end && start < self.rows() {
                    self.screen_mut().region = start..end;
                    self.goto(0, 0, true);
                }
            }
            (None, b's') => self.save_cursor(),
            (None, b'u') => self.restore_cursor(),
            (None, b'n') => match c.value(0, 0) {
                5 => emit(Event::Reply(b"\x1b[0n".to_vec())),
                6 => {
                    let row = if self.modes.origin {
                        pos.row.saturating_sub(self.screen().region.start)
                    } else {
                        pos.row
                    };
                    emit(Event::Reply(
                        format!("\x1b[{};{}R", row + 1, pos.col + 1).into_bytes(),
                    ));
                }
                _ => {}
            },
            (Some(b'?'), b'n') if c.value(0, 0) == 6 => emit(Event::Reply(
                format!("\x1b[?{};{}R", pos.row + 1, pos.col + 1).into_bytes(),
            )),
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
                    self.alternate = Screen::new(self.cols(), self.rows(), 0, true);
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
                            let channels: Vec<_> = params
                                .iter()
                                .skip(index + 2)
                                .take(3)
                                .map(|p| p.first().copied().flatten())
                                .collect();
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
                    self.link = std::str::from_utf8(uri)
                        .ok()
                        .filter(|s| {
                            !s.is_empty() && s.len() <= 2048 && !s.chars().any(char::is_control)
                        })
                        .map(Arc::from);
                    if self.link.is_some() {
                        self.link_id = self.link_id.wrapping_add(1).max(1);
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
                    (rgb >> 16) & 255,
                    (rgb >> 8) & 255,
                    rgb & 255
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
        self.alternate.resize(cols, rows, false);
        emit(Event::Resize {
            history_delta: delta,
            history: self.main.history.len(),
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
            self.main.rows[row].cells.fill(Cell::default());
            self.main.rows[row].wrapped = false;
            self.main.rows[row].generation = self.main.rows[row].generation.wrapping_add(1);
        }
        self.main.cursor = Cursor::default();
        self.main.saved_cursor = Cursor::default();
        self.main.region = 0..rows;
        self.main.keyboard_stack.clear();
        self.main.keyboard_flags = 0;
        self.main.selection = None;
        self.main.tabs = (0..cols).map(|col| col != 0 && col % 8 == 0).collect();
        self.alternate = Screen::new(cols, rows, 0, true);
        self.modes = Modes::default();
        self.style = Style::default();
        self.palette.reset();
        self.link = None;
        self.modes.grapheme_clusters = self.grapheme_supported;
        self.grapheme_target = None;
        self.charsets = [false; 4];
        self.charset = 0;
        self.title.clear();
        self.title_stack.clear();
        self.last_printed = None;
        self.saved_style = [Style::default(); 2];
        self.saved_origin = [false; 2];
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
}
