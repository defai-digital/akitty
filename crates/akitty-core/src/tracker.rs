//! Keeps Kitty graphics placements attached to the terminal content.
//!
//! [`Tracker`] stands in for the terminal as the VT handler: every parser
//! callback is forwarded to the [`Term`] unchanged, while the grid changes
//! alacritty performs (scroll region scrolls, linefeeds, autowrap, reverse
//! index, insert/delete lines, erase display, reset) are mirrored into the
//! graphics placement list. Replacing the old history-growth heuristic with
//! this mirror keeps images moving once scrollback is full and makes regions,
//! RI, IL/DL and ED behave like kitty.

use crate::graphics::Graphics;
use crate::model::Events;
use alacritty_terminal::grid::{Dimensions, GridCell};
use alacritty_terminal::index::{Column, Line, Point};
use alacritty_terminal::term::{Term, TermMode};
use alacritty_terminal::vte::ansi::{
    Attr, CharsetIndex, ClearMode, CursorShape, CursorStyle, Handler, Hyperlink, KeyboardModes,
    KeyboardModesApplyBehavior, LineClearMode, Mode, ModifyOtherKeys, PrivateMode, Rgb, ScpCharPath, ScpUpdateMode,
    StandardCharset, TabulationClearMode, cursor_icon::CursorIcon,
};

/// Grid bookkeeping the model keeps between parser runs.
#[derive(Clone)]
pub struct Tracking {
    /// Mirror of the terminal's scrolling region: 0-based grid lines, end exclusive.
    region: (usize, usize),
    rows: usize,
    cols: usize,
    history: usize,
}

impl Tracking {
    pub fn new(cols: usize, rows: usize) -> Self {
        Self { region: (0, rows), rows, cols, history: 0 }
    }
}

/// Forwards parser callbacks to the terminal and mirrors grid changes into
/// the graphics placements. Constructed per parse run; the persistent mirror
/// lives in [`Tracking`].
pub struct Tracker<'a> {
    term: &'a mut Term<Events>,
    graphics: &'a mut Graphics,
    tracking: &'a mut Tracking,
}

impl<'a> Tracker<'a> {
    pub fn new(term: &'a mut Term<Events>, graphics: &'a mut Graphics, tracking: &'a mut Tracking) -> Self {
        Self { term, graphics, tracking }
    }

    /// Catches up with changes made outside the parser, i.e. resizes: the
    /// terminal resets the scroll region and reflows lines into or out of
    /// history, which moves main-screen placements along.
    pub fn sync(&mut self) {
        let rows = self.term.grid().screen_lines();
        let cols = self.term.grid().columns();
        let history = self.term.grid().history_size();
        if rows != self.tracking.rows || cols != self.tracking.cols {
            let delta = history as i64 - self.tracking.history as i64;
            if delta != 0 {
                self.graphics.shift_main(delta as i32, history);
            }
            self.tracking.region = (0, rows);
        }
        self.tracking.rows = rows;
        self.tracking.cols = cols;
        self.tracking.history = history;
    }

    fn alt(&self) -> bool {
        self.term.mode().contains(TermMode::ALT_SCREEN)
    }

    /// Applies a scroll of the mirrored region by `lines` rows (`> 0` moves
    /// content up) on the active screen. Runs after the forwarded call, so
    /// the history size already includes rotated lines.
    fn region_scrolled(&mut self, lines: i32) {
        let alt = self.alt();
        let (start, end) = self.tracking.region;
        // The text engine clamps SU/SD to the region height. Only upward scrolling
        // rotates content into history; reverse scrolling never brings history back.
        let lines = lines.clamp(-((end - start) as i32), (end - start) as i32);
        self.graphics.scroll(alt, start as i32, end as i32, lines, !alt && start == 0 && lines > 0, self.term.grid().history_size());
        self.tracking.history = self.term.grid().history_size();
    }

    /// After a display write: at the bottom of the scroll region an autowrap
    /// scrolls the region up instead of moving the cursor down.
    fn wrap_scrolled(&mut self, before: Point) {
        let after = self.term.grid().cursor.point;
        if before.line.0 + 1 == self.tracking.region.1 as i32
            && after.line.0 == before.line.0
            && after.column.0 < before.column.0
        {
            self.region_scrolled(1);
        }
    }

    /// Rows `clear_viewport` will rotate into history: one past the last
    /// viewport row holding an occupied cell, mirroring alacritty's own scan.
    fn viewport_rows_in_use(&self) -> i32 {
        let grid = self.term.grid();
        let rows = grid.screen_lines();
        let mut iter = grid.iter_from(Point::new(Line(0), Column(0)));
        let mut last = -1;
        while iter.point().line.0 < rows as i32 {
            if !iter.cell().is_empty() {
                last = iter.point().line.0;
            }
            if iter.next().is_none() {
                break;
            }
        }
        1 + last
    }
}

impl Handler for Tracker<'_> {
    fn set_title(&mut self, title: Option<String>) {
        self.term.set_title(title)
    }

    fn set_cursor_style(&mut self, style: Option<CursorStyle>) {
        self.term.set_cursor_style(style)
    }

    fn set_cursor_shape(&mut self, shape: CursorShape) {
        self.term.set_cursor_shape(shape)
    }

    fn input(&mut self, c: char) {
        let before = self.term.grid().cursor.point;
        self.term.input(c);
        self.wrap_scrolled(before);
    }

    fn goto(&mut self, line: i32, col: usize) {
        self.term.goto(line, col)
    }

    fn goto_line(&mut self, line: i32) {
        self.term.goto_line(line)
    }

    fn goto_col(&mut self, col: usize) {
        self.term.goto_col(col)
    }

    fn insert_blank(&mut self, count: usize) {
        self.term.insert_blank(count)
    }

    fn move_up(&mut self, count: usize) {
        self.term.move_up(count)
    }

    fn move_down(&mut self, count: usize) {
        self.term.move_down(count)
    }

    fn identify_terminal(&mut self, intermediate: Option<char>) {
        self.term.identify_terminal(intermediate)
    }

    fn device_status(&mut self, kind: usize) {
        self.term.device_status(kind)
    }

    fn move_forward(&mut self, count: usize) {
        self.term.move_forward(count)
    }

    fn move_backward(&mut self, count: usize) {
        self.term.move_backward(count)
    }

    fn move_down_and_cr(&mut self, count: usize) {
        self.term.move_down_and_cr(count)
    }

    fn move_up_and_cr(&mut self, count: usize) {
        self.term.move_up_and_cr(count)
    }

    fn put_tab(&mut self, count: u16) {
        self.term.put_tab(count)
    }

    fn backspace(&mut self) {
        self.term.backspace()
    }

    fn carriage_return(&mut self) {
        self.term.carriage_return()
    }

    fn linefeed(&mut self) {
        let at_bottom = self.term.grid().cursor.point.line.0 + 1 == self.tracking.region.1 as i32;
        self.term.linefeed();
        if at_bottom {
            self.region_scrolled(1);
        }
    }

    fn bell(&mut self) {
        self.term.bell()
    }

    fn substitute(&mut self) {
        self.term.substitute()
    }

    fn newline(&mut self) {
        let at_bottom = self.term.grid().cursor.point.line.0 + 1 == self.tracking.region.1 as i32;
        self.term.newline();
        if at_bottom {
            self.region_scrolled(1);
        }
    }

    fn set_horizontal_tabstop(&mut self) {
        self.term.set_horizontal_tabstop()
    }

    fn scroll_up(&mut self, count: usize) {
        self.term.scroll_up(count);
        self.region_scrolled(count as i32);
    }

    fn scroll_down(&mut self, count: usize) {
        self.term.scroll_down(count);
        self.region_scrolled(-(count as i32));
    }

    fn insert_blank_lines(&mut self, count: usize) {
        // IL only acts with the cursor inside the region and shifts the
        // sub-region from the cursor line to the region bottom down.
        let line = self.term.grid().cursor.point.line.0;
        let end = self.tracking.region.1 as i32;
        let inside = line >= self.tracking.region.0 as i32 && line < end;
        self.term.insert_blank_lines(count);
        if inside {
            self.graphics.scroll(self.alt(), line, end, -(count as i32), false, 0);
        }
    }

    fn delete_lines(&mut self, count: usize) {
        let line = self.term.grid().cursor.point.line.0;
        let end = self.tracking.region.1 as i32;
        let inside = line >= self.tracking.region.0 as i32 && line < end;
        self.term.delete_lines(count);
        if inside {
            self.graphics.scroll(self.alt(), line, end, count as i32, false, 0);
        }
    }

    fn erase_chars(&mut self, count: usize) {
        self.term.erase_chars(count)
    }

    fn delete_chars(&mut self, count: usize) {
        self.term.delete_chars(count)
    }

    fn move_backward_tabs(&mut self, count: u16) {
        self.term.move_backward_tabs(count)
    }

    fn move_forward_tabs(&mut self, count: u16) {
        self.term.move_forward_tabs(count)
    }

    fn save_cursor_position(&mut self) {
        self.term.save_cursor_position()
    }

    fn restore_cursor_position(&mut self) {
        self.term.restore_cursor_position()
    }

    fn clear_line(&mut self, mode: LineClearMode) {
        self.term.clear_line(mode)
    }

    fn clear_screen(&mut self, mode: ClearMode) {
        match mode {
            ClearMode::All => {
                let alt = self.alt();
                let rows = self.term.grid().screen_lines();
                if alt {
                    self.term.clear_screen(mode);
                    self.graphics.delete_visible(true, rows);
                } else {
                    // alacritty first scrolls the used viewport into history.
                    let scrolls = self.viewport_rows_in_use();
                    self.term.clear_screen(mode);
                    self.graphics.delete_visible(false, rows);
                    if scrolls > 0 {
                        let history = self.term.grid().history_size();
                        self.graphics.shift_main(scrolls, history);
                        self.tracking.history = history;
                    }
                }
            }
            ClearMode::Saved => {
                self.term.clear_screen(mode);
                self.graphics.delete_scrollback();
            }
            _ => self.term.clear_screen(mode),
        }
    }

    fn clear_tabs(&mut self, mode: TabulationClearMode) {
        self.term.clear_tabs(mode)
    }

    fn set_tabs(&mut self, count: u16) {
        self.term.set_tabs(count)
    }

    fn reset_state(&mut self) {
        self.term.reset_state();
        self.graphics.reset();
        self.tracking.region = (0, self.term.grid().screen_lines());
    }

    fn reverse_index(&mut self) {
        let at_top = self.term.grid().cursor.point.line.0 == self.tracking.region.0 as i32;
        self.term.reverse_index();
        if at_top {
            self.region_scrolled(-1);
        }
    }

    fn terminal_attribute(&mut self, attr: Attr) {
        self.term.terminal_attribute(attr)
    }

    fn set_mode(&mut self, mode: Mode) {
        self.term.set_mode(mode)
    }

    fn unset_mode(&mut self, mode: Mode) {
        self.term.unset_mode(mode)
    }

    fn report_mode(&mut self, mode: Mode) {
        self.term.report_mode(mode)
    }

    fn set_private_mode(&mut self, mode: PrivateMode) {
        self.term.set_private_mode(mode)
    }

    fn unset_private_mode(&mut self, mode: PrivateMode) {
        self.term.unset_private_mode(mode)
    }

    fn report_private_mode(&mut self, mode: PrivateMode) {
        self.term.report_private_mode(mode)
    }

    fn set_scrolling_region(&mut self, top: usize, bottom: Option<usize>) {
        // Mirror alacritty exactly: 1-based parameters, a missing bottom means the screen bottom, `top >= bottom` is
        // ignored (the previous region stays) and both ends are then clamped to the screen.
        let rows = self.term.grid().screen_lines();
        let bottom_line = bottom.unwrap_or(rows);
        if top < bottom_line { self.tracking.region = (top.saturating_sub(1).min(rows), bottom_line.min(rows)); }
        self.term.set_scrolling_region(top, bottom);
    }

    fn set_keypad_application_mode(&mut self) {
        self.term.set_keypad_application_mode()
    }

    fn unset_keypad_application_mode(&mut self) {
        self.term.unset_keypad_application_mode()
    }

    fn set_active_charset(&mut self, index: CharsetIndex) {
        self.term.set_active_charset(index)
    }

    fn configure_charset(&mut self, index: CharsetIndex, charset: StandardCharset) {
        self.term.configure_charset(index, charset)
    }

    fn set_color(&mut self, index: usize, color: Rgb) {
        self.term.set_color(index, color)
    }

    fn dynamic_color_sequence(&mut self, prefix: String, index: usize, terminator: &str) {
        self.term.dynamic_color_sequence(prefix, index, terminator)
    }

    fn reset_color(&mut self, index: usize) {
        self.term.reset_color(index)
    }

    fn clipboard_store(&mut self, clipboard: u8, text: &[u8]) {
        self.term.clipboard_store(clipboard, text)
    }

    fn clipboard_load(&mut self, clipboard: u8, terminator: &str) {
        self.term.clipboard_load(clipboard, terminator)
    }

    fn decaln(&mut self) {
        self.term.decaln()
    }

    fn push_title(&mut self) {
        self.term.push_title()
    }

    fn pop_title(&mut self) {
        self.term.pop_title()
    }

    fn text_area_size_pixels(&mut self) {
        self.term.text_area_size_pixels()
    }

    fn text_area_size_chars(&mut self) {
        self.term.text_area_size_chars()
    }

    fn set_hyperlink(&mut self, hyperlink: Option<Hyperlink>) {
        self.term.set_hyperlink(hyperlink)
    }

    fn set_mouse_cursor_icon(&mut self, icon: CursorIcon) {
        self.term.set_mouse_cursor_icon(icon)
    }

    fn report_keyboard_mode(&mut self) {
        self.term.report_keyboard_mode()
    }

    fn push_keyboard_mode(&mut self, mode: KeyboardModes) {
        self.term.push_keyboard_mode(mode)
    }

    fn pop_keyboard_modes(&mut self, count: u16) {
        self.term.pop_keyboard_modes(count)
    }

    fn set_keyboard_mode(&mut self, mode: KeyboardModes, behavior: KeyboardModesApplyBehavior) {
        self.term.set_keyboard_mode(mode, behavior)
    }

    fn set_modify_other_keys(&mut self, mode: ModifyOtherKeys) {
        self.term.set_modify_other_keys(mode)
    }

    fn report_modify_other_keys(&mut self) {
        self.term.report_modify_other_keys()
    }

    fn set_scp(&mut self, char_path: ScpCharPath, update_mode: ScpUpdateMode) {
        self.term.set_scp(char_path, update_mode)
    }
}
