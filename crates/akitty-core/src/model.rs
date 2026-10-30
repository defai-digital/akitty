use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::{Config, Osc52, Term, TermMode, cell::Flags};
use alacritty_terminal::vte::ansi::{Color, CursorShape, Processor, Rgb};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy)]
pub struct Size {
    pub cols: usize,
    pub rows: usize,
}
impl Size {
    pub fn validate(cols: usize, rows: usize) -> Result<Self, String> {
        if !(2..=512).contains(&cols) || !(1..=256).contains(&rows) || cols * rows > 32768 {
            Err("invalid terminal dimensions (2..512 columns, 1..256 rows, <=32768 cells)".into())
        } else {
            Ok(Self { cols, rows })
        }
    }
}
impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

#[derive(Clone, Default)]
pub struct Events(pub Arc<Mutex<VecDeque<Event>>>);
impl EventListener for Events {
    fn send_event(&self, event: Event) {
        if matches!(
            event,
            Event::Wakeup | Event::MouseCursorDirty | Event::CursorBlinkingChange
        ) {
            return;
        }
        if let Ok(mut events) = self.0.lock()
            && events.len() < 128
        {
            events.push_back(event);
        }
    }
}

pub struct Model {
    pub term: Term<Events>,
    pub parser: Processor,
    pub events: Events,
    pub size: Size,
    pub revision: u64,
    pub title: String,
    pub clipboard: Vec<String>,
    pub error: Option<String>,
    pub exited: bool,
    pub exit_code: Option<u32>,
}
impl Model {
    pub fn new(size: Size) -> Self {
        let events = Events::default();
        let config = Config {
            scrolling_history: 5000,
            osc52: Osc52::CopyPaste,
            kitty_keyboard: false,
            ..Config::default()
        };
        Self {
            term: Term::new(config, &size, events.clone()),
            parser: Processor::new(),
            events,
            size,
            revision: 1,
            title: "Akitty".into(),
            clipboard: Vec::new(),
            error: None,
            exited: false,
            exit_code: None,
        }
    }
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<u8> {
        self.parser.advance(&mut self.term, bytes);
        self.revision = self.revision.saturating_add(1);
        let events: Vec<_> = self
            .events
            .0
            .lock()
            .map(|mut q| q.drain(..).collect())
            .unwrap_or_default();
        let mut replies = Vec::new();
        for event in events {
            match event {
                Event::Title(title) => {
                    self.title = title
                        .chars()
                        .filter(|c| !c.is_control())
                        .take(128)
                        .collect()
                }
                Event::ResetTitle => self.title = "Akitty".into(),
                Event::ClipboardStore(_, text) => {
                    if self.clipboard.len() < 4 && text.len() <= 65536 {
                        self.clipboard.push(text);
                    }
                }
                Event::ClipboardLoad(_, format) => replies.extend_from_slice(format("").as_bytes()),
                Event::PtyWrite(text) => replies.extend_from_slice(text.as_bytes()),
                Event::ColorRequest(index, format) => {
                    replies.extend_from_slice(format(palette(index)).as_bytes())
                }
                Event::TextAreaSizeRequest(format) => replies.extend_from_slice(
                    format(alacritty_terminal::event::WindowSize {
                        num_lines: self.size.rows as u16,
                        num_cols: self.size.cols as u16,
                        cell_width: 0,
                        cell_height: 0,
                    })
                    .as_bytes(),
                ),
                _ => {}
            }
            if replies.len() > 65536 {
                replies.clear();
                self.error = Some("terminal reply limit exceeded".into());
                break;
            }
        }
        replies
    }
    pub fn snapshot(&mut self, since: Option<u64>) -> Value {
        if since == Some(self.revision) && self.clipboard.is_empty() {
            return json!({"changed": false});
        }
        let content = self.term.renderable_content();
        let mut cells = Vec::with_capacity(self.size.rows * self.size.cols);
        let mut text = vec![String::new(); self.size.rows];
        for indexed in content.display_iter {
            let row = indexed.point.line.0 + content.display_offset as i32;
            if row < 0 || row as usize >= self.size.rows {
                continue;
            }
            let cell = indexed.cell;
            let spacer = cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
            let hidden = cell.flags.contains(Flags::HIDDEN);
            let mut value = if spacer {
                String::new()
            } else if hidden {
                " ".into()
            } else {
                cell.c.to_string()
            };
            if !hidden
                && !spacer
                && let Some(extra) = cell.zerowidth()
            {
                value.extend(extra);
            }
            let mut fg = resolve(cell.fg, content.colors);
            let mut bg = resolve(cell.bg, content.colors);
            if cell.flags.contains(Flags::INVERSE) {
                std::mem::swap(&mut fg, &mut bg);
            }
            if cell.flags.contains(Flags::DIM) {
                fg = fg.map(|v| (v as f32 * 0.65) as u8);
            }
            let selected = content
                .selection
                .as_ref()
                .is_some_and(|s| s.contains(indexed.point));
            text[row as usize].push_str(&value);
            cells.push(json!({"row": row, "col": indexed.point.column.0, "text": value,
                "fg": fg, "bg": bg, "bold": cell.flags.contains(Flags::BOLD),
                "italic": cell.flags.contains(Flags::ITALIC), "underline": cell.flags.intersects(Flags::ALL_UNDERLINES),
                "selected": selected, "wide": cell.flags.contains(Flags::WIDE_CHAR)}));
        }
        let cursor_row = content.cursor.point.line.0 + content.display_offset as i32;
        let cursor_visible =
            content.cursor.shape != CursorShape::Hidden && content.display_offset == 0;
        json!({"changed": true, "revision": self.revision, "cols": self.size.cols, "rows": self.size.rows,
            "title": self.title, "cells": cells, "lines": text,
            "cursor": {"row": cursor_row, "col": content.cursor.point.column.0, "visible": cursor_visible},
            "bracketed_paste": content.mode.contains(TermMode::BRACKETED_PASTE),
            "app_cursor": content.mode.contains(TermMode::APP_CURSOR),
            "mouse_mode": content.mode.intersects(TermMode::MOUSE_MODE),
            "mouse_sgr": content.mode.contains(TermMode::SGR_MOUSE),
            "mouse_drag": content.mode.intersects(TermMode::MOUSE_DRAG | TermMode::MOUSE_MOTION),
            "mouse_motion": content.mode.contains(TermMode::MOUSE_MOTION),
            "focus_reporting": content.mode.contains(TermMode::FOCUS_IN_OUT),
            "alternate": content.mode.contains(TermMode::ALT_SCREEN),
            "offset": content.display_offset, "history": self.term.grid().history_size(),
            "clipboard": std::mem::take(&mut self.clipboard), "error": self.error,
            "exited": self.exited, "exit_code": self.exit_code})
    }
}

pub fn palette(index: usize) -> Rgb {
    const ANSI: [[u8; 3]; 16] = [
        [22, 26, 33],
        [237, 100, 109],
        [143, 202, 141],
        [229, 192, 123],
        [122, 162, 247],
        [187, 154, 247],
        [125, 207, 255],
        [203, 213, 225],
        [83, 93, 111],
        [255, 123, 132],
        [169, 226, 157],
        [255, 218, 145],
        [151, 183, 255],
        [211, 177, 255],
        [157, 233, 255],
        [241, 245, 249],
    ];
    let rgb = match index {
        0..=15 => ANSI[index],
        16..=231 => {
            let i = index - 16;
            let v = |x: usize| if x == 0 { 0 } else { (55 + 40 * x) as u8 };
            [v(i / 36), v(i / 6 % 6), v(i % 6)]
        }
        232..=255 => [8 + (index as u8 - 232) * 10; 3],
        257 | 268 => [18, 22, 29],
        259..=266 => ANSI[index - 259].map(|v| v / 2),
        _ => [218, 226, 239],
    };
    Rgb {
        r: rgb[0],
        g: rgb[1],
        b: rgb[2],
    }
}
fn resolve(color: Color, colors: &alacritty_terminal::term::color::Colors) -> [u8; 3] {
    let rgb = match color {
        Color::Spec(rgb) => rgb,
        Color::Indexed(i) => colors[i as usize].unwrap_or_else(|| palette(i as usize)),
        Color::Named(name) => colors[name].unwrap_or_else(|| palette(name as usize)),
    };
    [rgb.r, rgb.g, rgb.b]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn split_every_byte_boundary_matches_whole_stream() {
        let stream = "abc\x1b[2;4H中e\u{301}😀\x1b[31mRED\x1b[0m".as_bytes();
        let mut whole = Model::new(Size::validate(30, 5).unwrap());
        whole.feed(stream);
        let expected = whole.snapshot(None);
        for split in 0..=stream.len() {
            let mut model = Model::new(Size::validate(30, 5).unwrap());
            model.feed(&stream[..split]);
            model.feed(&stream[split..]);
            let got = model.snapshot(None);
            assert_eq!(got["cells"], expected["cells"], "split={split}");
            assert_eq!(got["cursor"], expected["cursor"]);
        }
    }
    #[test]
    fn cursor_report_and_device_status_reply() {
        let mut model = Model::new(Size::validate(30, 5).unwrap());
        assert_eq!(model.feed(b"\x1b[2;4H\x1b[6n"), b"\x1b[2;4R");
        assert_eq!(model.feed(b"\x1b[5n"), b"\x1b[0n");
    }
}
