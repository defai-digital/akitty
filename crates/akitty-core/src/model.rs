use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use crate::chrome::{self, Chrome, Filter as ChromeFilter, Segment as ChromeSegment};
use crate::graphics::{self, ApcFilter, Graphics, Segment};
use crate::placeholder;
use crate::tracker::{Tracker, Tracking};
use alacritty_terminal::index::{Column, Line, Point};
use alacritty_terminal::term::{Config, Osc52, Term, TermMode, cell::{Flags, LineLength}};
use alacritty_terminal::vte::ansi::{Color, CursorShape, Processor, Rgb};
use serde::Serialize;
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

/// One schema-1 cell, serialized directly as a keyed object by default.
/// Opt-in compact cells use `[row, col, text, fg, bg, attrs]` with packed colours,
/// followed by `ucolor` and `link` when set, to reduce native decoding work.
struct CellOut {
    compact: bool,
    row: i32,
    col: usize,
    text: String,
    fg: [u8; 3],
    bg: [u8; 3],
    /// [`ATTR_BOLD`] and the other attribute bits, with the underline style in bits 8-10.
    attrs: u16,
    ucolor: Option<[u8; 3]>,
    link: Option<usize>,
}

const ATTR_BOLD: u16 = 1;
const ATTR_ITALIC: u16 = 2;
const ATTR_UNDERLINE: u16 = 4;
const ATTR_SELECTED: u16 = 8;
const ATTR_WIDE: u16 = 16;
const ATTR_STRIKE: u16 = 32;
/// Bits 6 and 7. Underline style occupies bits 8–10, so these stay clear of it.
const ATTR_SEARCH: u16 = 64;
const ATTR_ACTIVE_SEARCH: u16 = 128;
const ATTR_USTYLE_SHIFT: u16 = 8;

impl Serialize for CellOut {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::{SerializeMap, SerializeSeq};
        if !self.compact {
            // Schema 1 predates positional cells; the faster layout is explicitly negotiated.
            let mut map = serializer.serialize_map(None)?;
            map.serialize_entry("row", &self.row)?;
            map.serialize_entry("col", &self.col)?;
            map.serialize_entry("text", &self.text)?;
            map.serialize_entry("fg", &self.fg)?;
            map.serialize_entry("bg", &self.bg)?;
            for (key, flag) in [("bold", ATTR_BOLD), ("italic", ATTR_ITALIC), ("underline", ATTR_UNDERLINE),
                ("selected", ATTR_SELECTED), ("wide", ATTR_WIDE)] {
                map.serialize_entry(key, &(self.attrs & flag != 0))?;
            }
            let style = self.attrs >> ATTR_USTYLE_SHIFT;
            if style != 0 { map.serialize_entry("ustyle", &style)?; }
            if let Some(color) = self.ucolor { map.serialize_entry("ucolor", &color)?; }
            if let Some(link) = self.link { map.serialize_entry("link", &link)?; }
            for (key, flag) in [("strike", ATTR_STRIKE), ("search", ATTR_SEARCH), ("active_search", ATTR_ACTIVE_SEARCH)] {
                if self.attrs & flag != 0 { map.serialize_entry(key, &true)?; }
            }
            return map.end();
        }
        let len = if self.link.is_some() { 8 } else if self.ucolor.is_some() { 7 } else { 6 };
        let mut seq = serializer.serialize_seq(Some(len))?;
        seq.serialize_element(&self.row)?;
        seq.serialize_element(&self.col)?;
        seq.serialize_element(&self.text)?;
        seq.serialize_element(&pack(self.fg))?;
        seq.serialize_element(&pack(self.bg))?;
        seq.serialize_element(&self.attrs)?;
        if len > 6 {
            seq.serialize_element(&self.ucolor.map(pack))?;
        }
        if let Some(link) = self.link {
            seq.serialize_element(&link)?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct CursorOut {
    row: i32,
    col: usize,
    visible: bool,
}

#[derive(Serialize)]
struct SnapshotOut<'a> {
    changed: bool,
    revision: u64,
    cols: usize,
    rows: usize,
    title: &'a str,
    cells: Vec<CellOut>,
    lines: Vec<&'a str>,
    links: &'a [String],
    images: Vec<Value>,
    animating: bool,
    cursor: CursorOut,
    bracketed_paste: bool,
    app_cursor: bool,
    mouse_mode: bool,
    mouse_sgr: bool,
    mouse_drag: bool,
    mouse_motion: bool,
    focus_reporting: bool,
    alternate: bool,
    kitty_flags: u8,
    offset: usize,
    history: usize,
    clipboard: Vec<String>,
    bell: bool,
    error: &'a Option<String>,
    exited: bool,
    exit_code: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chrome: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    partial: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    dirty: Option<Vec<usize>>,
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
    chrome: Chrome,
    chrome_filter: ChromeFilter,
    /// When false, a terminal `OSC 771` sequence does not change [`Self::chrome`].
    /// The C ABI chrome request still does.
    program_chrome: bool,
    /// Whether the last snapshot reported status text or progress, so an expiry
    /// can refresh a client that polls with `since` equal to the revision.
    reported_transient: bool,
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
    /// Literal find. Visible hits use `query`; `line` and the column span are the current hit.
    pub find: Option<FindMark>,
}

/// One literal hit. `end_col` is exclusive and stays on `line` (a hit does not cross a row).
pub struct FindMark {
    pub query: String,
    pub line: i32,
    pub start_col: usize,
    pub end_col: usize,
}

pub enum FindDirection {
    Latest,
    Next,
    Previous,
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
            chrome: Chrome::default(),
            chrome_filter: ChromeFilter::default(),
            program_chrome: true,
            reported_transient: false,
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
            find: None,
        }
    }
    /// Move to a literal hit and remember it for the next snapshot. `text` is 1..=256 bytes.
    pub fn search(&mut self, text: &str, direction: FindDirection) -> Value {
        let top = self.term.grid().topmost_line().0;
        let bottom = self.term.grid().bottommost_line().0;
        // A query change, or a grid scroll that moved other text onto the stored line, starts over.
        let origin = self.find.as_ref().is_some_and(|mark| mark.query == text).then(|| self.current_mark()).flatten();
        let (hit, wrapped) = match direction {
            FindDirection::Latest => (last_match(&self.term, text, top, bottom), false),
            FindDirection::Next => match origin {
                Some((line, start_col, _)) => match next_match(&self.term, text, line, start_col, top, bottom) {
                    Some(hit) => (Some(hit), false),
                    None => (first_match(&self.term, text, top, bottom), true),
                },
                None => (last_match(&self.term, text, top, bottom), false),
            },
            FindDirection::Previous => match origin {
                Some((line, start_col, _)) => match previous_match(&self.term, text, line, start_col, top, bottom) {
                    Some(hit) => (Some(hit), false),
                    None => (last_match(&self.term, text, top, bottom), true),
                },
                None => (last_match(&self.term, text, top, bottom), false),
            },
        };
        let Some(hit) = hit else {
            if self.find.take().is_some() {
                self.revision = self.revision.saturating_add(1);
            }
            return json!({"found": false});
        };
        self.find = Some(FindMark {
            query: text.to_string(),
            line: hit.0,
            start_col: hit.1,
            end_col: hit.2,
        });
        self.term.scroll_to_point(Point::new(Line(hit.0), Column(hit.1)));
        self.revision = self.revision.saturating_add(1);
        let row = hit.0 + self.term.grid().display_offset() as i32;
        json!({"found": true, "line": hit.0, "row": row, "col": hit.1, "end_col": hit.2, "wrapped": wrapped})
    }
    /// The stored hit, when that grid line still contains it. Alacritty line numbers are slots in
    /// a ring, so a scroll moves other text onto the same line and the old coordinates go stale.
    fn current_mark(&self) -> Option<(i32, usize, usize)> {
        let (query, line, start_col, end_col) = {
            let mark = self.find.as_ref()?;
            (mark.query.clone(), mark.line, mark.start_col, mark.end_col)
        };
        let top = self.term.grid().topmost_line().0;
        let bottom = self.term.grid().bottommost_line().0;
        if line < top || line > bottom { return None; }
        line_matches(&self.term, Line(line), &query)
            .into_iter()
            .find(|(start, end)| *start == start_col && *end == end_col)
            .map(|(start, end)| (line, start, end))
    }
    /// Match spans for each visible row, in viewport order. Empty when no find is active.
    fn visible_search_ranges(&self) -> Vec<Vec<(usize, usize)>> {
        let Some(find) = &self.find else { return Vec::new() };
        let offset = self.term.grid().display_offset() as i32;
        (0..self.size.rows)
            .map(|row| line_matches(&self.term, Line(row as i32 - offset), &find.query))
            .collect()
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Vec<u8> {
        let mut replies = Vec::new();
        let mut overflowed = false;
        for segment in self.chrome_filter.feed(bytes) {
            match segment {
                ChromeSegment::Pass(data) => self.feed_terminal(&data, &mut replies, &mut overflowed),
                // A program sequence is consumed either way, so it never lands in the grid.
                // With program chrome off it does not replace the document.
                ChromeSegment::Document(payload) => {
                    if self.program_chrome {
                        let _ = self.chrome.apply_bytes(&payload);
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
    /// The parser records a deadline; the host must expire it even when output stops.
    /// Return replies to the PTY owner rather than discarding buffered queries.
    pub fn expire_sync(&mut self) -> Vec<u8> {
        if !self.parser.sync_timeout().sync_timeout().is_some_and(|deadline| deadline <= std::time::Instant::now()) {
            return Vec::new();
        }
        let Model { term, graphics, tracking, parser, .. } = self;
        let mut handler = Tracker::new(term, graphics, tracking);
        handler.sync();
        parser.stop_sync(&mut handler);
        let events = self.events.0.lock().map(|mut queue| queue.drain(..).collect()).unwrap_or_default();
        let mut replies = Vec::new();
        self.handle_events(events, &mut replies);
        self.track_screen();
        self.revision = self.revision.saturating_add(1);
        replies
    }
    pub fn set_chrome(&mut self, input: chrome::ChromeInput) -> Result<(), String> {
        self.chrome.apply(input)?;
        self.revision = self.revision.saturating_add(1);
        Ok(())
    }
    pub fn set_program_chrome(&mut self, enabled: bool) {
        self.program_chrome = enabled;
        self.revision = self.revision.saturating_add(1);
    }
    fn feed_terminal(&mut self, bytes: &[u8], replies: &mut Vec<u8>, overflowed: &mut bool) {
        for segment in self.apc.feed(bytes) {
            match segment {
                Segment::Pass(data) => self.advance(&data, replies, overflowed),
                Segment::Apc(payload) => self.graphics_command(&payload, replies, overflowed),
                // CSI 16 t: cell size in pixels, height first, like kitty's reply.
                Segment::CellSizeQuery => {
                    if !*overflowed {
                        let (width, height) = self.cell_px;
                        let (width, height) =
                            (if width > 0 { width } else { 8 }, if height > 0 { height } else { 16 });
                        replies.extend_from_slice(format!("\x1b[6;{height};{width}t").as_bytes());
                    }
                }
            }
        }
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
                // alacritty answers DA1 as a bare VT102 (`CSI ? 6 c`); report VT220 with ANSI colour instead, since
                // clients such as kitten icat treat a reply without attributes as no reply and time out.
                Event::PtyWrite(text) if text == "\x1b[?6c" => replies.extend_from_slice(b"\x1b[?62;22c"),
                Event::PtyWrite(text) => replies.extend_from_slice(text.as_bytes()),
                Event::ColorRequest(index, format) => {
                    replies.extend_from_slice(format(palette(index)).as_bytes())
                }
                Event::TextAreaSizeRequest(_) => {
                    let width = if self.cell_px.0 > 0 { self.cell_px.0 } else { 8 };
                    let height = if self.cell_px.1 > 0 { self.cell_px.1 } else { 16 };
                    // The pinned upstream formatter multiplies u16 fields, which can overflow
                    // at valid grid/cell limits. CSI 14 t can represent the full pixel dimensions.
                    let width = self.size.cols as u64 * u64::from(width);
                    let height = self.size.rows as u64 * u64::from(height);
                    replies.extend_from_slice(format!("\x1b[4;{height};{width}t").as_bytes());
                }
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
    /// The snapshot as a parsed value with cells expanded to keyed objects (see
    /// [`expand_cell`]); the wire path uses [`Self::snapshot_json`].
    #[cfg(test)]
    pub fn snapshot(&mut self, since: Option<u64>) -> Value {
        let mut snapshot: Value = serde_json::from_str(&self.snapshot_json(since, true)).expect("snapshot is valid JSON");
        if let Some(cells) = snapshot.get_mut("cells").and_then(Value::as_array_mut) {
            for cell in cells {
                *cell = expand_cell(cell);
            }
        }
        snapshot
    }
    /// The snapshot JSON, serialized once from typed rows.
    pub fn snapshot_json(&mut self, since: Option<u64>, compact: bool) -> String {
        // Animations and chrome expiry can change without any new terminal input.
        if self.graphics.tick(std::time::Instant::now()) {
            self.revision = self.revision.saturating_add(1);
        }
        let now = chrome::now_ms();
        let transient = self.chrome.transient_visible(now);
        if since == Some(self.revision) && self.clipboard.is_empty() && !self.bell && transient == self.reported_transient {
            return r#"{"changed":false}"#.into();
        }
        self.reported_transient = transient;
        self.sync_graphics();
        let search_ranges = self.visible_search_ranges();
        let active_mark = self.current_mark();
        let rows = self.size.rows;
        // Pass 1 hashes every row without allocating, to learn which rows differ from the
        // client's copy (the snapshot it was last sent, identified by `since`).
        let mut hashes = vec![0xcbf2_9ce4_8422_2325_u64; rows];
        // Placeholder cells collected per visible row while hashing, so virtual
        // placements can be decoded into fragments after the pass.
        let mut placeholders: Vec<Vec<placeholder::Cell>> = vec![Vec::new(); rows];
        {
            let content = self.term.renderable_content();
            for indexed in content.display_iter {
                let row = indexed.point.line.0 + content.display_offset as i32;
                if row < 0 || row as usize >= rows {
                    continue;
                }
                let cell = indexed.cell;
                let selected = content.selection.as_ref().is_some_and(|s| s.contains(indexed.point));
                let (searched, active) = search_marks(&search_ranges, active_mark, row, indexed.point.column.0, indexed.point.line.0);
                let mut hash = mix(hashes[row as usize], u64::from(cell.c) | u64::from(cell.flags.bits()) << 32);
                hash = mix(hash, pack(resolve(cell.fg, content.colors)) << 32 | pack(resolve(cell.bg, content.colors)));
                hash = mix(hash, u64::from(selected) | u64::from(searched) << 1 | u64::from(active) << 2);
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
                if cell.c == placeholder::PLACEHOLDER && placeholder::color_id(cell.fg) != 0 {
                    placeholders[row as usize].push(placeholder::Cell {
                        col: indexed.point.column.0,
                        low: placeholder::color_id(cell.fg),
                        placement: cell.underline_color().map_or(0, placeholder::color_id),
                        marks: placeholder::marks(cell.zerowidth().unwrap_or(&[])),
                    });
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
            // A placeholder cell is an image slot; its glyph and marks stay blank
            // so only the decoded fragment is drawn.
            let slot = cell.c == placeholder::PLACEHOLDER
                && placeholder::color_id(cell.fg) != 0
                && placeholders[row as usize]
                    .binary_search_by_key(&indexed.point.column.0, |entry| entry.col)
                    .is_ok();
            let mut value = if spacer || slot {
                String::new()
            } else if hidden {
                " ".into()
            } else {
                cell.c.to_string()
            };
            if !hidden
                && !spacer
                && !slot
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
            let (searched, active) = search_marks(&search_ranges, active_mark, row, indexed.point.column.0, indexed.point.line.0);
            text[row as usize].push_str(&value);
            // Blank cells that draw as the clear colour carry no information beyond `lines`;
            // skipping them shrinks a quiet screen's snapshot by more than 90%.
            if cell.flags.is_empty()
                && cell.c == ' '
                && cell.zerowidth().is_none()
                && !selected
                && !searched
                && !active
                && bg == DEFAULT_BACKGROUND
                && cell.hyperlink().is_none()
                && cell.underline_color().is_none()
            {
                continue;
            }
            let ustyle = underline_style(cell.flags);
            let flag = |set: bool, bit: u16| if set { bit } else { 0 };
            let attrs = flag(cell.flags.contains(Flags::BOLD), ATTR_BOLD)
                | flag(cell.flags.contains(Flags::ITALIC), ATTR_ITALIC)
                | flag(cell.flags.intersects(Flags::ALL_UNDERLINES), ATTR_UNDERLINE)
                | flag(selected, ATTR_SELECTED)
                | flag(searched, ATTR_SEARCH)
                | flag(active, ATTR_ACTIVE_SEARCH)
                | flag(cell.flags.contains(Flags::WIDE_CHAR), ATTR_WIDE)
                | flag(cell.flags.contains(Flags::STRIKEOUT), ATTR_STRIKE)
                | u16::from(ustyle.unwrap_or(0)) << ATTR_USTYLE_SHIFT;
            cells.push(CellOut {
                compact,
                row,
                col: indexed.point.column.0,
                text: value,
                fg,
                bg,
                attrs,
                ucolor: ustyle.and(cell.underline_color()).map(|color| resolve(color, content.colors)),
                link: cell.hyperlink().and_then(|link| link_index(&mut links, link.uri())),
            });
        }
        let alternate = content.mode.contains(TermMode::ALT_SCREEN);
        // Drawn placements are bounded by the graphics limits, not cut here.
        let mut images: Vec<Value> = self
            .graphics
            .drawn(alternate)
            .iter()
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
        // Placeholder rows of virtual placements decode into fragment entries;
        // the bound keeps a hostile screen from bloating the snapshot.
        let cell_px = if self.cell_px.0 > 0 { self.cell_px } else { (8, 16) };
        let mut fragments = 0usize;
        for (row, cells) in placeholders.iter().enumerate() {
            if cells.is_empty() || fragments >= MAX_FRAGMENTS { continue; }
            let mut resolve = |image: u32, placement: u32| -> Option<placeholder::Grid> {
                let placed = self.graphics.virtual_placement(image, placement, alternate)?;
                let data = self.graphics.images.get(&image)?;
                Some(placeholder::Grid {
                    cols: placed.cols,
                    rows: placed.rows,
                    image_w: data.width,
                    image_h: data.height,
                })
            };
            for (fragment, placement) in placeholder::decode_row(row, cells, cell_px, &mut resolve) {
                if fragments >= MAX_FRAGMENTS { break; }
                let (Some(placed), Some(data)) =
                    (self.graphics.virtual_placement(fragment.image, placement, alternate), self.graphics.images.get(&fragment.image))
                else { break; };
                images.push(json!({"id": fragment.image, "gen": data.generation, "w": data.width, "h": data.height,
                    "row": fragment.row, "col": fragment.col, "cols": fragment.cols, "rows": 1, "z": placed.z,
                    "sx": fragment.sx, "sy": fragment.sy, "sw": fragment.sw, "sh": fragment.sh,
                    "ox": fragment.ox, "oy": fragment.oy, "dw": fragment.dw, "dh": fragment.dh}));
                fragments += 1;
            }
        }
        let cursor_row = content.cursor.point.line.0 + content.display_offset as i32;
        let cursor_visible =
            content.cursor.shape != CursorShape::Hidden && content.display_offset == 0;
        self.links = links;
        let dirty_rows: Vec<usize> = (0..rows).filter(|r| dirty[*r]).collect();
        let lines: Vec<&str> = dirty_rows.iter().map(|r| text[*r].as_str()).collect();
        let snapshot = SnapshotOut {
            changed: true,
            revision: self.revision,
            cols: self.size.cols,
            rows: self.size.rows,
            title: &self.title,
            cells,
            lines,
            links: &self.links,
            images,
            animating: self.graphics.animating(),
            cursor: CursorOut { row: cursor_row, col: content.cursor.point.column.0, visible: cursor_visible },
            bracketed_paste: content.mode.contains(TermMode::BRACKETED_PASTE),
            app_cursor: content.mode.contains(TermMode::APP_CURSOR),
            mouse_mode: content.mode.intersects(TermMode::MOUSE_MODE),
            mouse_sgr: content.mode.contains(TermMode::SGR_MOUSE),
            mouse_drag: content.mode.intersects(TermMode::MOUSE_DRAG | TermMode::MOUSE_MOTION),
            mouse_motion: content.mode.contains(TermMode::MOUSE_MOTION),
            focus_reporting: content.mode.contains(TermMode::FOCUS_IN_OUT),
            alternate: content.mode.contains(TermMode::ALT_SCREEN),
            kitty_flags: kitty_flags(content.mode),
            offset: content.display_offset,
            history: self.term.grid().history_size(),
            clipboard: std::mem::take(&mut self.clipboard),
            bell: std::mem::take(&mut self.bell),
            error: &self.error,
            exited: self.exited,
            exit_code: self.exit_code,
            chrome: self.chrome.to_json(now),
            partial: partial.then_some(true),
            dirty: partial.then_some(dirty_rows),
        };
        let json = serde_json::to_string(&snapshot).expect("snapshot fields serialize");
        // A crowded link table is rebuilt by the next full snapshot instead of growing without bound.
        let crowded = partial && self.links.len() > MAX_LINKS / 2;
        self.sent = (!crowded).then_some(SentRows {
            revision: self.revision,
            cols: self.size.cols,
            hashes,
        });
        json
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
fn search_marks(ranges: &[Vec<(usize, usize)>], active: Option<(i32, usize, usize)>, row: i32, col: usize, line: i32) -> (bool, bool) {
    let Some(spans) = usize::try_from(row).ok().and_then(|row| ranges.get(row)) else { return (false, false) };
    let searched = spans.iter().any(|(start, end)| col >= *start && col < *end);
    let active = active.is_some_and(|(mark_line, start, end)| line == mark_line && col >= start && col < end);
    (searched, active)
}
/// Literal hits on one grid line: `(start_col, end_col)` with `end_col` exclusive.
/// The text is the cell characters a person sees (primary plus zero-width), one row at a time.
fn line_matches(term: &Term<Events>, line: Line, query: &str) -> Vec<(usize, usize)> {
    if query.is_empty() { return Vec::new(); }
    let grid = term.grid();
    let row = &grid[line];
    let limit = row.line_length().0.min(grid.columns());
    let mut text = String::new();
    // Byte offset of each glyph, its column, and how many columns it occupies.
    let mut glyphs: Vec<(usize, usize, usize)> = Vec::new();
    let mut col = 0usize;
    while col < limit {
        let cell = &row[Column(col)];
        if cell.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
            col += 1;
            continue;
        }
        let width = if cell.flags.contains(Flags::WIDE_CHAR) { 2 } else { 1 };
        glyphs.push((text.len(), col, width));
        text.push(cell.c);
        if let Some(extra) = cell.zerowidth() {
            for ch in extra { text.push(*ch); }
        }
        col += 1;
    }
    let mut found = Vec::new();
    let mut from = 0usize;
    while from < text.len() {
        let Some(pos) = text[from..].find(query) else { break };
        let start = from + pos;
        let end = start + query.len();
        let start_glyph = glyphs.iter().rev().find(|glyph| glyph.0 <= start);
        let end_glyph = glyphs.iter().rev().find(|glyph| glyph.0 < end);
        if let (Some((_, col, _)), Some((_, end_col, width))) = (start_glyph, end_glyph) {
            found.push((*col, end_col + width));
        }
        if end <= from { break; }
        from = end;
    }
    found
}
fn first_match(term: &Term<Events>, query: &str, top: i32, bottom: i32) -> Option<(i32, usize, usize)> {
    if top > bottom { return None; }
    (top..=bottom).find_map(|line| line_matches(term, Line(line), query).into_iter().next().map(|(start, end)| (line, start, end)))
}
fn last_match(term: &Term<Events>, query: &str, top: i32, bottom: i32) -> Option<(i32, usize, usize)> {
    if top > bottom { return None; }
    (top..=bottom).rev().find_map(|line| line_matches(term, Line(line), query).into_iter().next_back().map(|(start, end)| (line, start, end)))
}
fn next_match(term: &Term<Events>, query: &str, line: i32, col: usize, top: i32, bottom: i32) -> Option<(i32, usize, usize)> {
    if (top..=bottom).contains(&line)
        && let Some((start, end)) = line_matches(term, Line(line), query).into_iter().find(|(start, _)| *start > col)
    {
        return Some((line, start, end));
    }
    first_match(term, query, line.saturating_add(1).max(top), bottom)
}
fn previous_match(term: &Term<Events>, query: &str, line: i32, col: usize, top: i32, bottom: i32) -> Option<(i32, usize, usize)> {
    if (top..=bottom).contains(&line)
        && let Some((start, end)) = line_matches(term, Line(line), query).into_iter().rev().find(|(start, _)| *start < col)
    {
        return Some((line, start, end));
    }
    last_match(term, query, top, line.saturating_sub(1).min(bottom))
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
/// A positional wire cell as a keyed object, the way the Swift client decodes it:
/// colours as RGB arrays, every flag present, optional fields only when set.
#[cfg(test)]
fn expand_cell(cell: &Value) -> Value {
    let rgb = |v: &Value| v.as_u64().map(|c| json!([c >> 16 & 255, c >> 8 & 255, c & 255]));
    let attrs = cell[5].as_u64().unwrap() as u16;
    let mut out = json!({"row": cell[0], "col": cell[1], "text": cell[2], "fg": rgb(&cell[3]), "bg": rgb(&cell[4]),
        "bold": attrs & ATTR_BOLD != 0, "italic": attrs & ATTR_ITALIC != 0, "underline": attrs & ATTR_UNDERLINE != 0,
        "selected": attrs & ATTR_SELECTED != 0, "wide": attrs & ATTR_WIDE != 0});
    let fields = out.as_object_mut().unwrap();
    if attrs >> ATTR_USTYLE_SHIFT != 0 {
        fields.insert("ustyle".into(), json!(attrs >> ATTR_USTYLE_SHIFT));
    }
    if let Some(color) = cell.get(6).and_then(rgb) {
        fields.insert("ucolor".into(), color);
    }
    if attrs & ATTR_STRIKE != 0 {
        fields.insert("strike".into(), json!(true));
    }
    if attrs & ATTR_SEARCH != 0 {
        fields.insert("search".into(), json!(true));
    }
    if attrs & ATTR_ACTIVE_SEARCH != 0 {
        fields.insert("active_search".into(), json!(true));
    }
    if let Some(link) = cell.get(7) {
        fields.insert("link".into(), link.clone());
    }
    out
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
/// Placeholder fragments per snapshot; rows already cap cells at 32,768.
const MAX_FRAGMENTS: usize = 4096;
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

    #[test]
    fn synchronized_expiry_returns_buffered_query_replies_once() {
        let mut model = super::Model::new(super::Size::validate(20, 4).unwrap(), 100);
        assert!(model.feed(b"\x1b[?2026h\x1b[6n").is_empty());
        std::thread::sleep(std::time::Duration::from_millis(200));
        assert_eq!(model.expire_sync(), b"\x1b[1;1R");
        assert!(model.expire_sync().is_empty());
    }
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
        let snapshot: Value = serde_json::from_str(&model.snapshot_json(None, true)).unwrap();
        assert_eq!(snapshot["links"], json!([]));
        // Positional cells: [row, col, text, fg, bg, attrs] with nothing trailing when unset.
        assert_eq!(snapshot["cells"][0], json!([0, 0, "h", 0xdae2ef, 0x12161d, 0]));
    }
    #[test]
    fn wire_cells_pack_attributes_and_trail_ucolor_then_link() {
        let mut model = Model::new(Size::validate(10, 2).unwrap(), 100);
        model.feed("\x1b[1;3;9;4:3;58;2;1;2;3mA\x1b[0m\x1b]8;;https://a.test\x07B\x1b]8;;\x07界".as_bytes());
        let snapshot: Value = serde_json::from_str(&model.snapshot_json(None, true)).unwrap();
        let cells = &snapshot["cells"];
        let attrs = ATTR_BOLD | ATTR_ITALIC | ATTR_UNDERLINE | ATTR_STRIKE | 3 << ATTR_USTYLE_SHIFT;
        assert_eq!(cells[0], json!([0, 0, "A", 0xdae2ef, 0x12161d, attrs, 0x010203]));
        // A link without an underline colour keeps the colour slot as null.
        assert_eq!(cells[1], json!([0, 1, "B", 0xdae2ef, 0x12161d, 0, null, 0]));
        assert_eq!(cells[2], json!([0, 2, "界", 0xdae2ef, 0x12161d, ATTR_WIDE]));
    }
    #[test]
    fn cursor_report_and_device_status_reply() {
        let mut model = Model::new(Size::validate(30, 5).unwrap(), 5000);
        assert_eq!(model.feed(b"\x1b[2;4H\x1b[6n"), b"\x1b[2;4R");
        assert_eq!(model.feed(b"\x1b[5n"), b"\x1b[0n");
    }
    #[test]
    fn primary_device_attributes_report_vt220_with_colour() {
        // kitten icat ends its graphics probe at the DA1 reply and treats a bare `CSI ? 6 c` as no reply.
        let mut model = Model::new(Size::validate(30, 5).unwrap(), 100);
        assert_eq!(model.feed(b"\x1b[c"), b"\x1b[?62;22c");
        assert_eq!(model.feed(b"\x1b[0c"), b"\x1b[?62;22c");
    }
    #[test]
    fn unicode_placeholders_become_image_fragments_with_blank_text() {
        let mut model = Model::new(Size::validate(30, 5).unwrap(), 100);
        model.cell_px = (8, 16);
        // A 2x2 image in a virtual 2x1 cell placement; the placeholder cells carry image id 5 in a 24-bit foreground.
        model.feed(format!("\x1b_Ga=t,f=24,s=2,v=2,i=5,q=2;{PIXEL}\x1b\\\x1b_Ga=p,U=1,i=5,c=2,r=1,q=2\x1b\\").as_bytes());
        model.feed("\x1b[38;2;0;0;5m\u{10EEEE}\u{305}\u{305}\u{10EEEE}\x1b[0m!".as_bytes());
        let snapshot = model.snapshot(None);
        let images = snapshot["images"].as_array().unwrap();
        assert_eq!(images.len(), 1, "{snapshot}");
        let fragment = &images[0];
        // The second cell inherits row 0 and the next column from its left neighbour.
        assert_eq!((fragment["row"].as_u64(), fragment["col"].as_u64(), fragment["cols"].as_u64()), (Some(0), Some(0), Some(2)));
        assert_eq!((fragment["dw"].as_u64(), fragment["dh"].as_u64(), fragment["sw"].as_u64()), (Some(16), Some(16), Some(2)));
        assert_eq!(snapshot["lines"][0].as_str().unwrap().trim_end(), "!");
        // The virtual placement itself is never drawn, and without placeholders nothing shows.
        model.feed(b"\x1b[2J");
        assert!(model.snapshot(None)["images"].as_array().unwrap().is_empty());
    }

    #[test]
    fn unicode_placeholders_resolve_duplicate_ids_on_the_current_screen() {
        for explicit in [false, true] {
            let mut model = Model::new(Size::validate(30, 5).unwrap(), 100);
            model.feed(format!("\x1b_Ga=t,f=24,s=2,v=2,i=5,q=2;{PIXEL}\x1b\\\x1b_Ga=p,U=1,i=5,p=7,c=2,r=1,z=3,q=2\x1b\\").as_bytes());
            let color = if explicit { "\x1b[58;2;0;0;7m" } else { "" };
            let placeholder = format!("\x1b[38;2;0;0;5m{color}\u{10EEEE}\u{305}\u{305}\x1b[0m");
            model.feed(placeholder.as_bytes());
            assert_eq!(model.snapshot(None)["images"][0]["z"], 3);
            model.feed(b"\x1b[?1049h\x1b_Ga=p,U=1,i=5,p=7,c=1,r=1,z=9,q=2\x1b\\");
            model.feed(placeholder.as_bytes());
            assert_eq!(model.snapshot(None)["images"][0]["z"], 9);
            model.feed(b"\x1b[?1049l");
            assert_eq!(model.snapshot(None)["images"][0]["z"], 3);
        }
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
        assert_eq!(fresh.feed(b"\x1b[14t"), b"\x1b[4;160;320t");
        assert_eq!(fresh.feed(b"\x1b[16t"), b"\x1b[6;16;8t");
    }

    #[test]
    fn window_pixel_reports_do_not_overflow_at_valid_grid_and_cell_limits() {
        for (cols, rows, expected) in [(512, 64, b"\x1b[4;32768;131072t".as_slice()), (128, 256, b"\x1b[4;131072;32768t".as_slice())] {
            let mut model = Model::new(Size::validate(cols, rows).unwrap(), 0);
            model.cell_px = (256, 512);
            assert_eq!(model.feed(b"\x1b[14t"), expected);
            model.feed(b"still responsive");
        }
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
