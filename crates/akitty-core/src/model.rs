use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use crate::graphics::{self, ApcFilter, Graphics, Segment};
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
    pub graphics: Graphics,
    apc: ApcFilter,
    /// Pixel size of one cell as reported by the host; (0, 0) until known.
    pub cell_px: (u32, u32),
    in_alt: bool,
    last_history: usize,
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
    pub fn new(size: Size, scrollback: usize) -> Self {
        let events = Events::default();
        let config = Config {
            scrolling_history: scrollback,
            osc52: Osc52::CopyPaste,
            kitty_keyboard: true,
            ..Config::default()
        };
        Self {
            graphics: Graphics::default(),
            apc: ApcFilter::default(),
            cell_px: (0, 0),
            in_alt: false,
            last_history: 0,
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
        let mut replies = Vec::new();
        let mut overflowed = false;
        for segment in self.apc.feed(bytes) {
            match segment {
                Segment::Pass(data) => self.advance(&data, &mut replies, &mut overflowed),
                Segment::Apc(payload) => self.graphics_command(&payload, &mut replies, &mut overflowed),
            }
        }
        self.revision = self.revision.saturating_add(1);
        if overflowed {
            replies.clear();
        }
        replies
    }
    fn advance(&mut self, data: &[u8], replies: &mut Vec<u8>, overflowed: &mut bool) {
        // The event queue holds 128 entries and every event needs at least one input byte,
        // so draining after each 64-byte slice guarantees none are dropped mid-chunk.
        for slice in data.chunks(64) {
            self.parser.advance(&mut self.term, slice);
            let events: Vec<_> = self
                .events
                .0
                .lock()
                .map(|mut q| q.drain(..).collect())
                .unwrap_or_default();
            if !*overflowed {
                *overflowed = self.handle_events(events, replies);
            }
            self.track_screen();
        }
    }
    /// Keeps image placements attached to their content as the screen scrolls or swaps.
    fn track_screen(&mut self) {
        let alt = self.term.mode().contains(TermMode::ALT_SCREEN);
        let history = self.term.grid().history_size();
        if alt != self.in_alt {
            if self.in_alt {
                self.graphics.leave_alternate_screen();
            }
            self.in_alt = alt;
        } else if !alt && history > self.last_history {
            self.graphics.scrolled((history - self.last_history) as i32, history);
        }
        self.last_history = history;
    }
    fn graphics_command(&mut self, payload: &[u8], replies: &mut Vec<u8>, overflowed: &mut bool) {
        let point = self.term.grid().cursor.point;
        let (width, height) = self.cell_px;
        let context = graphics::Context {
            line: point.line.0,
            col: point.column.0,
            alt: self.in_alt,
            cell_width: if width > 0 { width } else { 8 },
            cell_height: if height > 0 { height } else { 16 },
        };
        let outcome = self.graphics.handle(payload, &context);
        self.revision = self.revision.saturating_add(1);
        if !*overflowed {
            replies.extend_from_slice(&outcome.reply);
            if replies.len() > 65536 {
                replies.clear();
                self.error = Some("terminal reply limit exceeded".into());
                *overflowed = true;
            }
        }
        if let Some((rows, cols)) = outcome.advance {
            // Kitty moves the cursor past the image: down by its rows, right by its columns.
            let rows = rows.min(self.size.rows as u32);
            let cols = cols.min(self.size.cols as u32);
            let movement = format!("{}\x1b[{cols}C", "\n".repeat(rows.saturating_sub(1) as usize));
            self.advance(movement.as_bytes(), replies, overflowed);
        }
    }
    /// Applies parsed terminal events; returns true when the reply limit was exceeded.
    fn handle_events(&mut self, events: Vec<Event>, replies: &mut Vec<u8>) -> bool {
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
                        cell_width: self.cell_px.0 as u16,
                        cell_height: self.cell_px.1 as u16,
                    })
                    .as_bytes(),
                ),
                _ => {}
            }
            if replies.len() > 65536 {
                replies.clear();
                self.error = Some("terminal reply limit exceeded".into());
                return true;
            }
        }
        false
    }
    pub fn snapshot(&mut self, since: Option<u64>) -> Value {
        if since == Some(self.revision) && self.clipboard.is_empty() {
            return json!({"changed": false});
        }
        let content = self.term.renderable_content();
        let mut cells = Vec::with_capacity(self.size.rows * self.size.cols);
        let mut text = vec![String::new(); self.size.rows];
        // OSC 8 targets are deduplicated into a bounded table; cells reference them by index.
        let mut links: Vec<String> = Vec::new();
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
            let mut entry = json!({"row": row, "col": indexed.point.column.0, "text": value,
                "fg": fg, "bg": bg, "bold": cell.flags.contains(Flags::BOLD),
                "italic": cell.flags.contains(Flags::ITALIC), "underline": cell.flags.intersects(Flags::ALL_UNDERLINES),
                "selected": selected, "wide": cell.flags.contains(Flags::WIDE_CHAR)});
            // Optional fields are omitted when unset to keep snapshots compact.
            if let Some(fields) = entry.as_object_mut() {
                if let Some(style) = underline_style(cell.flags) {
                    fields.insert("ustyle".into(), json!(style));
                    if let Some(color) = cell.underline_color() {
                        fields.insert("ucolor".into(), json!(resolve(color, content.colors)));
                    }
                }
                if cell.flags.contains(Flags::STRIKEOUT) {
                    fields.insert("strike".into(), json!(true));
                }
                if let Some(link) = cell.hyperlink()
                    && let Some(index) = link_index(&mut links, link.uri())
                {
                    fields.insert("link".into(), json!(index));
                }
            }
            cells.push(entry);
        }
        let alternate = content.mode.contains(TermMode::ALT_SCREEN);
        let images: Vec<Value> = self
            .graphics
            .placements
            .iter()
            .filter(|p| p.alt == alternate)
            .filter_map(|p| {
                let image = self.graphics.images.get(&p.image)?;
                let row = p.line + content.display_offset as i32;
                if row + p.rows as i32 <= 0 || row >= self.size.rows as i32 {
                    return None;
                }
                Some(json!({"id": p.image, "gen": image.generation, "w": image.width, "h": image.height,
                    "row": row, "col": p.col, "cols": p.cols, "rows": p.rows, "z": p.z}))
            })
            .take(64)
            .collect();
        let cursor_row = content.cursor.point.line.0 + content.display_offset as i32;
        let cursor_visible =
            content.cursor.shape != CursorShape::Hidden && content.display_offset == 0;
        let links_empty = links.is_empty();
        let mut snapshot = json!({"changed": true, "revision": self.revision, "cols": self.size.cols, "rows": self.size.rows,
            "title": self.title, "cells": cells, "lines": text, "links": links, "images": images,
            "cursor": {"row": cursor_row, "col": content.cursor.point.column.0, "visible": cursor_visible},
            "bracketed_paste": content.mode.contains(TermMode::BRACKETED_PASTE),
            "app_cursor": content.mode.contains(TermMode::APP_CURSOR),
            "mouse_mode": content.mode.intersects(TermMode::MOUSE_MODE),
            "mouse_sgr": content.mode.contains(TermMode::SGR_MOUSE),
            "mouse_drag": content.mode.intersects(TermMode::MOUSE_DRAG | TermMode::MOUSE_MOTION),
            "mouse_motion": content.mode.contains(TermMode::MOUSE_MOTION),
            "focus_reporting": content.mode.contains(TermMode::FOCUS_IN_OUT),
            "alternate": content.mode.contains(TermMode::ALT_SCREEN),
            "kitty_flags": kitty_flags(content.mode),
            "offset": content.display_offset, "history": self.term.grid().history_size(),
            "clipboard": std::mem::take(&mut self.clipboard), "error": self.error,
            "exited": self.exited, "exit_code": self.exit_code});
        if links_empty && let Some(object) = snapshot.as_object_mut() {
            object.remove("links");
        }
        snapshot
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
/// Active Kitty keyboard flags: 1 disambiguate, 2 event types, 4 alternate keys,
/// 8 all keys as escape codes, 16 associated text.
fn kitty_flags(mode: TermMode) -> u8 {
    [
        (TermMode::DISAMBIGUATE_ESC_CODES, 1),
        (TermMode::REPORT_EVENT_TYPES, 2),
        (TermMode::REPORT_ALTERNATE_KEYS, 4),
        (TermMode::REPORT_ALL_KEYS_AS_ESC, 8),
        (TermMode::REPORT_ASSOCIATED_TEXT, 16),
    ]
    .iter()
    .filter(|(flag, _)| mode.contains(*flag))
    .fold(0, |bits, (_, bit)| bits | bit)
}
/// Underline kind for a cell: 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
fn underline_style(flags: Flags) -> Option<u8> {
    if flags.contains(Flags::DOUBLE_UNDERLINE) {
        Some(2)
    } else if flags.contains(Flags::UNDERCURL) {
        Some(3)
    } else if flags.contains(Flags::DOTTED_UNDERLINE) {
        Some(4)
    } else if flags.contains(Flags::DASHED_UNDERLINE) {
        Some(5)
    } else if flags.contains(Flags::UNDERLINE) {
        Some(1)
    } else {
        None
    }
}
const MAX_LINKS: usize = 256;
const MAX_LINK_BYTES: usize = 2048;
/// Interns a hyperlink target; oversized, control-bearing or excess targets are dropped.
fn link_index(links: &mut Vec<String>, uri: &str) -> Option<usize> {
    if uri.is_empty() || uri.len() > MAX_LINK_BYTES || uri.chars().any(char::is_control) {
        return None;
    }
    if let Some(index) = links.iter().position(|known| known == uri) {
        return Some(index);
    }
    if links.len() >= MAX_LINKS {
        return None;
    }
    links.push(uri.to_owned());
    Some(links.len() - 1)
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
        let mut whole = Model::new(Size::validate(30, 5).unwrap(), 5000);
        whole.feed(stream);
        let expected = whole.snapshot(None);
        for split in 0..=stream.len() {
            let mut model = Model::new(Size::validate(30, 5).unwrap(), 5000);
            model.feed(&stream[..split]);
            model.feed(&stream[split..]);
            let got = model.snapshot(None);
            assert_eq!(got["cells"], expected["cells"], "split={split}");
            assert_eq!(got["cursor"], expected["cursor"]);
        }
    }
    #[test]
    fn styled_underlines_strikethrough_and_hyperlinks_are_reported() {
        let mut model = Model::new(Size::validate(40, 3).unwrap(), 100);
        model.feed(b"\x1b[4:3;58;2;1;2;3mC\x1b[0m\x1b[9mS\x1b[0m\x1b]8;;https://a.test/x\x07L\x1b]8;;\x07N");
        let snapshot = model.snapshot(None);
        let cells = &snapshot["cells"];
        assert_eq!(cells[0]["ustyle"], 3);
        assert_eq!(cells[0]["ucolor"], json!([1, 2, 3]));
        assert_eq!(cells[1]["strike"], true);
        assert_eq!(cells[2]["link"], 0);
        assert_eq!(snapshot["links"], json!(["https://a.test/x"]));
        assert!(cells[3].get("link").is_none() && cells[3].get("strike").is_none());
    }
    #[test]
    fn hyperlink_table_is_bounded_and_rejects_control_bytes() {
        let mut links = Vec::new();
        assert_eq!(link_index(&mut links, "https://a"), Some(0));
        assert_eq!(link_index(&mut links, "https://a"), Some(0));
        assert_eq!(link_index(&mut links, "https://a\u{1b}b"), None);
        assert_eq!(link_index(&mut links, &"x".repeat(MAX_LINK_BYTES + 1)), None);
        for i in 1..MAX_LINKS {
            assert_eq!(link_index(&mut links, &format!("https://h/{i}")), Some(i));
        }
        assert_eq!(link_index(&mut links, "https://overflow"), None);
    }
    #[test]
    fn graphics_query_reply_reaches_the_pty_even_when_split() {
        let query = b"\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c";
        for split in 0..query.len() {
            let mut model = Model::new(Size::validate(30, 5).unwrap(), 100);
            let mut replies = model.feed(&query[..split]);
            replies.extend(model.feed(&query[split..]));
            let text = String::from_utf8(replies).unwrap();
            assert!(text.starts_with("\x1b_Gi=31337;OK\x1b\\"), "split {split}: {text:?}");
            assert!(text.contains("\x1b[?"), "device attributes still answered: {text:?}");
        }
    }
    #[test]
    fn alternate_screen_images_disappear_when_it_is_left() {
        let mut model = Model::new(Size::validate(30, 5).unwrap(), 100);
        model.feed(b"\x1b[?1049h\x1b_Ga=T,f=24,s=1,v=1,i=3,q=2;AAAA\x1b\\");
        assert_eq!(model.snapshot(None)["images"].as_array().unwrap().len(), 1);
        model.feed(b"\x1b[?1049l");
        assert_eq!(model.snapshot(None)["images"].as_array().unwrap().len(), 0);
        assert!(model.graphics.images.is_empty());
    }
    #[test]
    fn kitty_keyboard_flags_follow_the_protocol_stack_per_screen() {
        let mut model = Model::new(Size::validate(30, 5).unwrap(), 100);
        assert_eq!(model.snapshot(None)["kitty_flags"], 0);
        assert_eq!(model.feed(b"\x1b[?u"), b"\x1b[?0u");
        model.feed(b"\x1b[>5u");
        assert_eq!(model.snapshot(None)["kitty_flags"], 5);
        assert_eq!(model.feed(b"\x1b[?u"), b"\x1b[?5u");
        model.feed(b"\x1b[>8u");
        assert_eq!(model.snapshot(None)["kitty_flags"], 8);
        model.feed(b"\x1b[<u");
        assert_eq!(model.snapshot(None)["kitty_flags"], 5);
        // The alternate screen has its own stack, so a full-screen app cannot leak flags to the shell.
        model.feed(b"\x1b[?1049h");
        assert_eq!(model.snapshot(None)["kitty_flags"], 0);
        model.feed(b"\x1b[=31;1u");
        assert_eq!(model.snapshot(None)["kitty_flags"], 31);
        model.feed(b"\x1b[?1049l");
        assert_eq!(model.snapshot(None)["kitty_flags"], 5);
    }
    #[test]
    fn plain_snapshots_omit_optional_fields() {
        let mut model = Model::new(Size::validate(10, 2).unwrap(), 100);
        model.feed(b"hi");
        let snapshot = model.snapshot(None);
        assert!(snapshot.get("links").is_none());
        let cell = snapshot["cells"][0].as_object().unwrap();
        for key in ["ustyle", "ucolor", "strike", "link"] {
            assert!(!cell.contains_key(key), "{key}");
        }
    }
    #[test]
    fn cursor_report_and_device_status_reply() {
        let mut model = Model::new(Size::validate(30, 5).unwrap(), 5000);
        assert_eq!(model.feed(b"\x1b[2;4H\x1b[6n"), b"\x1b[2;4R");
        assert_eq!(model.feed(b"\x1b[5n"), b"\x1b[0n");
    }
}
