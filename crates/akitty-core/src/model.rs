use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use crate::graphics::{self, ApcFilter, Graphics, Segment};
use crate::tracker::{Tracker, Tracking};
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

/// What the client holds after the last snapshot sent: lets the next one carry only changed rows.
struct SentRows {
    revision: u64,
    cols: usize,
    hashes: Vec<u64>,
}

pub struct Model {
    sent: Option<SentRows>,
    /// OSC 8 targets; stable across partial snapshots so unchanged rows keep valid indices.
    links: Vec<String>,
    pub graphics: Graphics,
    apc: ApcFilter,
    /// Pixel size of one cell as reported by the host; (0, 0) until known.
    pub cell_px: (u32, u32),
    in_alt: bool,
    tracking: Tracking,
    pub term: Term<Events>,
    pub parser: Processor,
    pub events: Events,
    pub size: Size,
    pub revision: u64,
    pub title: String,
    pub clipboard: Vec<String>,
    /// BEL seen since the last snapshot; the client decides how to sound it.
    pub bell: bool,
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
            sent: None,
            links: Vec::new(),
            graphics: Graphics::default(),
            apc: ApcFilter::default(),
            cell_px: (0, 0),
            in_alt: false,
            tracking: Tracking::new(size.cols, size.rows),
            term: Term::new(config, &size, events.clone()),
            parser: Processor::new(),
            events,
            size,
            revision: 1,
            title: "Akitty".into(),
            clipboard: Vec::new(),
            bell: false,
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
                // CSI 16 t: cell size in pixels, height first, like kitty's reply.
                Segment::CellSizeQuery => {
                    if !overflowed {
                        let (width, height) = self.cell_px;
                        let (width, height) =
                            (if width > 0 { width } else { 8 }, if height > 0 { height } else { 16 });
                        replies.extend_from_slice(format!("\x1b[6;{height};{width}t").as_bytes());
                    }
                }
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
            self.parse(slice);
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
    /// Parses one chunk through the tracker, which forwards every callback to
    /// the terminal and mirrors grid changes into the graphics placements.
    fn parse(&mut self, slice: &[u8]) {
        let Model { term, graphics, tracking, parser, .. } = self;
        let mut handler = Tracker::new(term, graphics, tracking);
        handler.sync();
        parser.advance(&mut handler, slice);
    }
    /// Applies pending resize-driven placement shifts; a snapshot read after
    /// a resize without new output still reports correct placement rows.
    fn sync_graphics(&mut self) {
        let Model { term, graphics, tracking, .. } = self;
        Tracker::new(term, graphics, tracking).sync();
    }
    /// Drops alternate-screen images when that screen is left.
    fn track_screen(&mut self) {
        let alt = self.term.mode().contains(TermMode::ALT_SCREEN);
        if alt != self.in_alt {
            self.graphics.cancel_pending();
            if self.in_alt {
                self.graphics.leave_alternate_screen();
            }
            self.in_alt = alt;
        }
    }
    fn graphics_command(&mut self, payload: &[u8], replies: &mut Vec<u8>, overflowed: &mut bool) {
        let point = self.term.grid().cursor.point;
        let (width, height) = self.cell_px;
        let context = graphics::Context {
            line: point.line.0,
            col: point.column.0,
            alt: self.in_alt,
            rows: self.size.rows,
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
                Event::Bell => self.bell = true,
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
        if since == Some(self.revision) && self.clipboard.is_empty() && !self.bell {
            return json!({"changed": false});
        }
        self.sync_graphics();
        let rows = self.size.rows;
        // Pass 1 hashes every row without allocating, to learn which rows differ from the
        // client's copy (the snapshot it was last sent, identified by `since`).
        let mut hashes = vec![0xcbf2_9ce4_8422_2325_u64; rows];
        {
            let content = self.term.renderable_content();
            for indexed in content.display_iter {
                let row = indexed.point.line.0 + content.display_offset as i32;
                if row < 0 || row as usize >= rows {
                    continue;
                }
                let cell = indexed.cell;
                let selected = content.selection.as_ref().is_some_and(|s| s.contains(indexed.point));
                let mut hash = mix(hashes[row as usize], u64::from(cell.c) | u64::from(cell.flags.bits()) << 32);
                hash = mix(hash, pack(resolve(cell.fg, content.colors)) << 32 | pack(resolve(cell.bg, content.colors)));
                hash = mix(hash, u64::from(selected));
                if let Some(extra) = cell.zerowidth() {
                    for ch in extra {
                        hash = mix(hash, u64::from(*ch));
                    }
                }
                if let Some(link) = cell.hyperlink() {
                    for byte in link.uri().bytes() {
                        hash = mix(hash, u64::from(byte));
                    }
                }
                if let Some(color) = cell.underline_color() {
                    hash = mix(hash, pack(resolve(color, content.colors)) | 1 << 40);
                }
                hashes[row as usize] = hash;
            }
        }
        let partial = self.sent.as_ref().is_some_and(|sent| {
            Some(sent.revision) == since && sent.cols == self.size.cols && sent.hashes.len() == rows
        });
        let mut dirty: Vec<bool> = match (&self.sent, partial) {
            (Some(sent), true) => (0..rows).map(|r| sent.hashes[r] != hashes[r]).collect(),
            _ => vec![true; rows],
        };
        // When every row changed a partial buys nothing, and a full snapshot also rebuilds the link table.
        let partial = partial && dirty.iter().any(|changed| !changed);
        if !partial {
            dirty.fill(true);
        }
        let content = self.term.renderable_content();
        let mut cells = Vec::new();
        let mut text = vec![String::new(); rows];
        // OSC 8 targets are deduplicated into a bounded table; cells reference them by index.
        // A full snapshot rebuilds it; a partial one extends it so unchanged rows stay valid.
        let mut links: Vec<String> = if partial { std::mem::take(&mut self.links) } else { Vec::new() };
        for indexed in content.display_iter {
            let row = indexed.point.line.0 + content.display_offset as i32;
            if row < 0 || row as usize >= self.size.rows || !dirty[row as usize] {
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
            // Blank cells that draw as the clear colour carry no information beyond `lines`;
            // skipping them shrinks a quiet screen's snapshot by more than 90%.
            if cell.flags.is_empty()
                && cell.c == ' '
                && cell.zerowidth().is_none()
                && !selected
                && bg == DEFAULT_BACKGROUND
                && cell.hyperlink().is_none()
                && cell.underline_color().is_none()
            {
                continue;
            }
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
        // Visible placements are bounded by the graphics limits, not cut here.
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
                    "row": row, "col": p.col, "cols": p.cols, "rows": p.rows, "z": p.z,
                    "sx": p.src_x, "sy": p.src_y, "sw": p.src_w, "sh": p.src_h,
                    "ox": p.off_x, "oy": p.off_y}))
            })
            .collect();
        let cursor_row = content.cursor.point.line.0 + content.display_offset as i32;
        let cursor_visible =
            content.cursor.shape != CursorShape::Hidden && content.display_offset == 0;
        let links_empty = links.is_empty();
        self.links = links.clone();
        let dirty_rows: Vec<usize> = (0..rows).filter(|r| dirty[*r]).collect();
        let lines: Vec<&String> = dirty_rows.iter().map(|r| &text[*r]).collect();
        let mut snapshot = json!({"changed": true, "revision": self.revision, "cols": self.size.cols, "rows": self.size.rows,
            "title": self.title, "cells": cells, "lines": lines, "links": links, "images": images,
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
            "clipboard": std::mem::take(&mut self.clipboard), "bell": std::mem::take(&mut self.bell), "error": self.error,
            "exited": self.exited, "exit_code": self.exit_code});
        if let Some(object) = snapshot.as_object_mut() {
            if links_empty {
                object.remove("links");
            }
            if partial {
                object.insert("partial".into(), json!(true));
                object.insert("dirty".into(), json!(dirty_rows));
            }
        }
        // A crowded link table is rebuilt by the next full snapshot instead of growing without bound.
        let crowded = partial && self.links.len() > MAX_LINKS / 2;
        self.sent = (!crowded).then_some(SentRows {
            revision: self.revision,
            cols: self.size.cols,
            hashes,
        });
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
/// Cheap order-dependent 64-bit mixing for row signatures; a collision only delays one row's repaint.
#[inline]
fn mix(hash: u64, value: u64) -> u64 {
    (hash ^ value).wrapping_mul(0x0000_0100_0000_01b3).rotate_left(23)
}
#[inline]
fn pack(rgb: [u8; 3]) -> u64 {
    u64::from(rgb[0]) << 16 | u64::from(rgb[1]) << 8 | u64::from(rgb[2])
}
/// Resolved default background; the host clears to this colour, so matching cells need no entry.
const DEFAULT_BACKGROUND: [u8; 3] = [18, 22, 29];
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
    fn blank_default_cells_are_omitted_but_meaningful_blanks_are_kept() {
        let mut model = Model::new(Size::validate(10, 3).unwrap(), 100);
        model.feed(b"hi\x1b[2;1H\x1b[44m \x1b[0m\x1b[3;1H\x1b[4m \x1b[0m");
        let snapshot = model.snapshot(None);
        let cells = snapshot["cells"].as_array().unwrap();
        let at = |row: i64, col: i64| cells.iter().find(|c| c["row"] == row && c["col"] == col);
        assert_eq!(cells.len(), 4, "h, i, a blue-background space and an underlined space");
        assert!(at(1, 0).is_some() && at(2, 0).is_some());
        assert!(at(0, 5).is_none());
        assert_eq!(snapshot["lines"][0], "hi        ", "lines still hold every column");
        let point = alacritty_terminal::index::Point::new(alacritty_terminal::index::Line(0), alacritty_terminal::index::Column(4));
        let mut selection = alacritty_terminal::selection::Selection::new(
            alacritty_terminal::selection::SelectionType::Simple,
            point,
            alacritty_terminal::index::Side::Left,
        );
        selection.update(point, alacritty_terminal::index::Side::Right);
        model.term.selection = Some(selection);
        let selected = model.snapshot(None);
        assert!(selected["cells"].as_array().unwrap().iter().any(|c| c["row"] == 0 && c["col"] == 4 && c["selected"] == true));
    }
    /// What a client does with a snapshot: replace dirty rows of its copy, keep the rest.
    fn apply(base: &mut (Vec<Value>, Vec<String>), snapshot: &Value) {
        let incoming: Vec<Value> = snapshot["cells"].as_array().unwrap().clone();
        if snapshot.get("partial") == Some(&json!(true)) {
            let dirty: Vec<usize> = snapshot["dirty"].as_array().unwrap().iter().map(|r| r.as_u64().unwrap() as usize).collect();
            base.0.retain(|c| !dirty.contains(&(c["row"].as_u64().unwrap() as usize)));
            base.0.extend(incoming);
            for (slot, line) in dirty.iter().zip(snapshot["lines"].as_array().unwrap()) {
                base.1[*slot] = line.as_str().unwrap().to_string();
            }
        } else {
            base.0 = incoming;
            base.1 = snapshot["lines"].as_array().unwrap().iter().map(|l| l.as_str().unwrap().to_string()).collect();
        }
        base.0.sort_by_key(|c| (c["row"].as_u64().unwrap(), c["col"].as_u64().unwrap()));
    }
    #[test]
    fn partial_snapshots_reconstruct_exactly_what_a_full_snapshot_holds() {
        let steps: [&[u8]; 18] = [
            b"hello world\r\nsecond line", b"\x1b[2;3Hxx", b"\x1b[31;44mcolor\x1b[0m", b"\x1b[4:3;58;2;1;2;3mcurly\x1b[0m",
            b"\x1b]8;;https://a.test/\x07link\x1b]8;;\x07", b"\x1b]8;;https://b.test/\x07other\x1b]8;;\x07", b"\x1b[1;1H\x1b[2K",
            b"\r\n\r\n\r\n\r\n\r\nscrolling now", "\x1b[2;1H中文e\u{301}".as_bytes(), b"\x1b[?1049h\x1b[Halt screen", b"\x1b[3;1H\x1b[7minverse\x1b[0m",
            b"\x1b[?1049l", b"\x1b[2J\x1b[H", b"\x1b[9mstrike\x1b[0m", b"line\r\nline\r\nline\r\nline\r\nline\r\nline\r\n",
            b"\x1b]8;;https://c.test/\x07linked\x1b]8;;\x07", b"\x1b[5;1Hbottom", b"tail",
        ];
        let mut model = Model::new(Size::validate(24, 5).unwrap(), 100);
        let mut client: (Vec<Value>, Vec<String>) = (Vec::new(), Vec::new());
        let mut since = None;
        let mut partials = 0;
        for (index, step) in steps.iter().enumerate() {
            model.feed(step);
            // Every other step also changes the selection, which affects rows without new output.
            if index % 4 == 1 {
                let point = alacritty_terminal::index::Point::new(alacritty_terminal::index::Line(0), alacritty_terminal::index::Column(1));
                let mut selection = alacritty_terminal::selection::Selection::new(
                    alacritty_terminal::selection::SelectionType::Simple, point, alacritty_terminal::index::Side::Left);
                selection.update(point, alacritty_terminal::index::Side::Right);
                model.term.selection = Some(selection);
                model.revision += 1;
            }
            let snapshot = model.snapshot(since);
            partials += usize::from(snapshot.get("partial") == Some(&json!(true)));
            apply(&mut client, &snapshot);
            since = snapshot["revision"].as_u64();
            let mut fresh = Model::new(Size::validate(24, 5).unwrap(), 100);
            // A second model that saw the same history, asked for a full snapshot, is the reference.
            for earlier in &steps[..=index] {
                fresh.feed(earlier);
                if index % 4 == 1 && std::ptr::eq(earlier, step) {
                    fresh.term.selection = model.term.selection.clone();
                }
            }
            fresh.term.selection = model.term.selection.clone();
            let full = fresh.snapshot(None);
            let mut expected: Vec<Value> = full["cells"].as_array().unwrap().clone();
            expected.sort_by_key(|c| (c["row"].as_u64().unwrap(), c["col"].as_u64().unwrap()));
            // Link indices may differ (a partial keeps its table stable); the targets they name may not.
            let resolve_links = |cells: &[Value], table: &Value| -> Vec<Value> {
                cells.iter().map(|c| {
                    let mut cell = c.clone();
                    let target = c.get("link").and_then(|i| table.get(i.as_u64().unwrap() as usize)).cloned();
                    let object = cell.as_object_mut().unwrap();
                    object.remove("link");
                    if let Some(target) = target {
                        object.insert("target".into(), target);
                    }
                    cell
                }).collect()
            };
            assert_eq!(resolve_links(&client.0, &snapshot["links"]), resolve_links(&expected, &full["links"]), "cells diverged after step {index}");
            let expected_lines: Vec<String> = full["lines"].as_array().unwrap().iter().map(|l| l.as_str().unwrap().to_string()).collect();
            assert_eq!(client.1, expected_lines, "lines diverged after step {index}");
        }
        assert!(partials >= 8, "most steps should have been partial, got {partials}");
    }
    #[test]
    fn a_stale_since_resize_or_missing_baseline_gets_a_full_snapshot() {
        let mut model = Model::new(Size::validate(20, 4).unwrap(), 100);
        model.feed(b"abc");
        let first = model.snapshot(None);
        assert!(first.get("partial").is_none());
        let revision = first["revision"].as_u64().unwrap();
        model.feed(b"d");
        // The client names a revision the server never sent: full.
        assert!(model.snapshot(Some(revision - 1)).get("partial").is_none());
        let second = model.snapshot(None);
        model.feed(b"e");
        let partial = model.snapshot(second["revision"].as_u64());
        assert_eq!(partial["partial"], true);
        assert_eq!(partial["dirty"], json!([0]));
        // Resize changes the row count, so the next one is full again.
        let sent = partial["revision"].as_u64();
        model.term.resize(Size::validate(20, 6).unwrap());
        model.size = Size::validate(20, 6).unwrap();
        model.revision += 1;
        assert!(model.snapshot(sent).get("partial").is_none());
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

    /// A 2x2 RGB frame, base64 of 12 zero bytes; small enough to inline.
    const PIXEL: &str = "AAAAAAAAAAAAAAAA";
    fn place(id: u32) -> String {
        format!("\x1b_Ga=T,f=24,s=2,v=2,i={id},q=2,C=1;{PIXEL}\x1b\\")
    }

    #[test]
    fn size_reports_answer_window_pixels_cells_and_cell_pixels() {
        let mut model = Model::new(Size::validate(40, 10).unwrap(), 100);
        model.cell_px = (8, 16);
        assert_eq!(model.feed(b"\x1b[14t"), b"\x1b[4;160;320t");
        assert_eq!(model.feed(b"\x1b[18t"), b"\x1b[8;10;40t");
        assert_eq!(model.feed(b"\x1b[16t"), b"\x1b[6;16;8t");
        // Without a reported cell size the documented 8x16 fallback answers.
        let mut fresh = Model::new(Size::validate(40, 10).unwrap(), 100);
        assert_eq!(fresh.feed(b"\x1b[16t"), b"\x1b[6;16;8t");
    }

    #[test]
    fn placements_keep_following_scrolls_after_scrollback_is_full() {
        let mut model = Model::new(Size::validate(20, 5).unwrap(), 100);
        model.cell_px = (8, 16);
        model.feed(place(1).as_bytes());
        assert_eq!(model.graphics.placements.len(), 1);
        // The cursor needs four linefeeds to reach the bottom of five rows,
        // after which every linefeed scrolls the image one line further up.
        model.feed("\r\n".repeat(50).as_bytes());
        assert_eq!(model.graphics.placements[0].line, -46);
        model.feed("\r\n".repeat(20000).as_bytes());
        assert!(model.graphics.placements.is_empty(), "placement must leave with the text");
        assert_eq!(model.term.grid().history_size(), 100);
        assert!(model.graphics.images.contains_key(&1), "named image data survives");
        assert!(
            model.snapshot(None)["lines"][4].as_str().unwrap().trim().is_empty(),
            "text kept scrolling after scrollback was full"
        );
    }

    #[test]
    fn wrapping_text_scrolls_the_screen_and_moves_placements() {
        let mut model = Model::new(Size::validate(10, 3).unwrap(), 50);
        model.cell_px = (8, 16);
        model.feed(b"\r\n\r\n");
        model.feed(place(1).as_bytes());
        model.feed(b"0123456789");
        assert_eq!(model.graphics.placements[0].line, 2);
        // The eleventh character wraps at the bottom of the screen, which
        // scrolls the region up instead of moving the cursor further down.
        model.feed(b"x");
        assert_eq!(model.graphics.placements[0].line, 1);
    }

    #[test]
    fn decstbm_scrolls_move_only_placements_inside_the_region() {
        let mut model = Model::new(Size::validate(20, 10).unwrap(), 50);
        model.cell_px = (8, 16);
        let line = |model: &Model, id: u32| {
            model
                .graphics
                .placements
                .iter()
                .find(|p| p.image == id)
                .unwrap()
                .line
        };
        // Region 0-based lines [1, 5); an image inside it (not on the border,
        // since content scrolled out of the region is discarded) and one outside.
        model.feed(b"\x1b[2;5r\x1b[3;1H");
        model.feed(place(1).as_bytes());
        model.feed(b"\x1b[9;1H");
        model.feed(place(2).as_bytes());
        assert_eq!((line(&model, 1), line(&model, 2)), (2, 8));
        // A linefeed on the region's bottom line scrolls only the region.
        model.feed(b"\x1b[5;1H\n");
        assert_eq!((line(&model, 1), line(&model, 2)), (1, 8), "outside the region nothing moves");
        // Reverse index on the region's top line scrolls the region back down.
        model.feed(b"\x1b[2;1H\x1bM");
        assert_eq!((line(&model, 1), line(&model, 2)), (2, 8));
        // A linefeed outside the region, even at the screen bottom, scrolls nothing.
        model.feed(b"\x1b[10;1H\n");
        assert_eq!((line(&model, 1), line(&model, 2)), (2, 8));
    }

    #[test]
    fn insert_and_delete_lines_shift_the_placements_below_the_cursor() {
        let mut model = Model::new(Size::validate(20, 10).unwrap(), 50);
        model.cell_px = (8, 16);
        model.feed(b"\x1b[3;1H");
        model.feed(place(1).as_bytes());
        assert_eq!(model.graphics.placements[0].line, 2);
        model.feed(b"\x1b[3;1H\x1b[1L");
        assert_eq!(model.graphics.placements[0].line, 3, "IL pushes content down");
        // DL above the placement pulls it back up; DL on its own line would
        // delete it, because that line's content is removed.
        model.feed(b"\x1b[3;1H\x1b[1M");
        assert_eq!(model.graphics.placements[0].line, 2, "DL pulls it back up");
        // IL with the cursor outside the scroll region is ignored entirely.
        model.feed(b"\x1b[2;5r\x1b[9;1H\x1b[1L");
        assert_eq!(model.graphics.placements[0].line, 2);
    }

    #[test]
    fn erase_display_deletes_visible_or_scrollback_placements() {
        let mut model = Model::new(Size::validate(20, 5).unwrap(), 50);
        model.cell_px = (8, 16);
        let line = |model: &Model, id: u32| {
            model
                .graphics
                .placements
                .iter()
                .find(|p| p.image == id)
                .unwrap()
                .line
        };
        model.feed(b"\x1b[1;1H");
        model.feed(place(1).as_bytes());
        model.feed("\r\n".repeat(8).as_bytes());
        model.feed(b"\x1b[1;1Hx");
        model.feed(place(2).as_bytes());
        assert_eq!((line(&model, 1), line(&model, 2)), (-4, 0));
        // ED 2 keeps scrollback images but moves them up by the viewport
        // rows alacritty scrolls into history: one occupied row here.
        model.feed(b"\x1b[2J");
        assert_eq!(line(&model, 1), -5, "scrollback placement follows the cleared text");
        assert!(!model.graphics.placements.iter().any(|p| p.image == 2));
        // ED 3 removes the placements that live in scrollback.
        model.feed(b"\x1b[3J");
        assert!(model.graphics.placements.is_empty());
        assert!(
            model.graphics.images.contains_key(&1) && model.graphics.images.contains_key(&2),
            "named image data is not freed by ED"
        );
        // ED 2 on the alternate screen deletes its visible placements.
        model.feed(b"\x1b[?1049h\x1b[1;1H");
        model.feed(place(3).as_bytes());
        model.feed(b"\x1b[2J");
        assert!(model.graphics.placements.is_empty());
    }

    #[test]
    fn resize_reflow_shifts_main_placements_by_the_history_delta() {
        let mut model = Model::new(Size::validate(20, 5).unwrap(), 50);
        model.cell_px = (8, 16);
        model.feed(b"\x1b[1;1H");
        model.feed(place(1).as_bytes());
        model.feed(b"\x1b[5;1H");
        model.feed(place(2).as_bytes());
        assert_eq!((model.graphics.placements[0].line, model.graphics.placements[1].line), (0, 4));
        // Shrinking by two rows reflows those lines into history: every
        // placement moves up by two; the top one lands in scrollback.
        let size = Size::validate(20, 3).unwrap();
        model.term.resize(size);
        model.size = size;
        model.revision += 1;
        let snapshot = model.snapshot(None);
        assert_eq!(model.graphics.placements[0].line, -2);
        assert_eq!(model.graphics.placements[1].line, 2);
        assert_eq!(snapshot["images"].as_array().unwrap().len(), 1, "only the viewport image shows");
        // Growing back restores the scrollback placement to the viewport.
        let size = Size::validate(20, 5).unwrap();
        model.term.resize(size);
        model.size = size;
        model.revision += 1;
        model.snapshot(None);
        assert_eq!(model.graphics.placements[0].line, 0);
    }
    /// (text, wide) of the cell at `row`, `col` in a full snapshot.
    fn cell_at(snapshot: &Value, row: usize, col: usize) -> (String, bool) {
        let cell = snapshot["cells"].as_array().unwrap().iter().find(|c| c["row"] == row && c["col"] == col).unwrap();
        (cell["text"].as_str().unwrap().to_string(), cell["wide"] == true)
    }
    #[test]
    fn cjk_and_fullwidth_characters_take_two_columns_and_keep_neighbours_aligned() {
        let mut model = Model::new(Size::validate(20, 12).unwrap(), 100);
        let rows = ["a中b", "ひらがな", "한글a", "「，。」", "ＡＢx", "\u{1112}\u{1161}x", "ｱｲｳ"];
        for (row, text) in rows.iter().enumerate() { model.feed(format!("\x1b[{};1H{text}", row + 1).as_bytes()); }
        let snap = model.snapshot(None);
        assert_eq!(cell_at(&snap, 0, 0), ("a".into(), false));
        assert_eq!(cell_at(&snap, 0, 1), ("中".into(), true));
        assert_eq!(cell_at(&snap, 0, 3), ("b".into(), false));
        for (col, ch) in [(0, "ひ"), (2, "ら"), (4, "が"), (6, "な")] { assert_eq!(cell_at(&snap, 1, col), (ch.into(), true)); }
        assert_eq!(cell_at(&snap, 2, 0), ("한".into(), true));
        assert_eq!(cell_at(&snap, 2, 2), ("글".into(), true));
        assert_eq!(cell_at(&snap, 2, 4), ("a".into(), false));
        for (col, ch) in [(0, "「"), (2, "，"), (4, "。"), (6, "」")] { assert_eq!(cell_at(&snap, 3, col), (ch.into(), true)); }
        assert_eq!(cell_at(&snap, 4, 0), ("Ａ".into(), true));
        assert_eq!(cell_at(&snap, 4, 2), ("Ｂ".into(), true));
        assert_eq!(cell_at(&snap, 4, 4), ("x".into(), false));
        // Conjoining jamo share one two-column cell, kept as typed (the renderer composes them when drawing).
        assert_eq!(cell_at(&snap, 5, 0), ("\u{1112}\u{1161}".into(), true));
        assert_eq!(cell_at(&snap, 5, 2), ("x".into(), false));
        // Halfwidth katakana stay single-column.
        for (col, ch) in [(0, "ｱ"), (1, "ｲ"), (2, "ｳ")] { assert_eq!(cell_at(&snap, 6, col), (ch.into(), false)); }
    }
    #[test]
    fn combining_marks_and_ambiguous_width_symbols_stay_single_column() {
        let mut model = Model::new(Size::validate(20, 4).unwrap(), 100);
        model.feed("\x1b[1;1He\u{301}x\x1b[2;1H→●○│x".as_bytes());
        let snap = model.snapshot(None);
        assert_eq!(cell_at(&snap, 0, 0), ("e\u{301}".into(), false));
        assert_eq!(cell_at(&snap, 0, 1), ("x".into(), false));
        for (col, ch) in [(0, "→"), (1, "●"), (2, "○"), (3, "│"), (4, "x")] { assert_eq!(cell_at(&snap, 1, col), (ch.into(), false)); }
    }
    #[test]
    fn emoji_sequences_follow_the_wcwidth_model_that_grapheme_mode_off_implies() {
        let mut model = Model::new(Size::validate(20, 4).unwrap(), 100);
        // Apps only get grapheme-cluster widths after DECRQM reports mode 2027; it is unsupported, so each wide
        // scalar takes its own two columns and VS16 does not widen a narrow base. Cursor maths in apps then agrees.
        assert_eq!(model.feed(b"\x1b[?2027$p"), b"\x1b[?2027;0$y");
        model.feed("\x1b[1;1H😀x\x1b[2;1H❤\u{fe0f}x\x1b[3;1H👨\u{200d}👩x".as_bytes());
        let snap = model.snapshot(None);
        assert_eq!(cell_at(&snap, 0, 0), ("😀".into(), true));
        assert_eq!(cell_at(&snap, 0, 2), ("x".into(), false));
        assert_eq!(cell_at(&snap, 1, 0), ("❤\u{fe0f}".into(), false));
        assert_eq!(cell_at(&snap, 1, 1), ("x".into(), false));
        assert_eq!(cell_at(&snap, 2, 0), ("👨\u{200d}".into(), true));
        assert_eq!(cell_at(&snap, 2, 2), ("👩".into(), true));
        assert_eq!(cell_at(&snap, 2, 4), ("x".into(), false));
    }
}
