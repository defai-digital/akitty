//! Terminal behavior implemented against public terminal protocol specifications.
//!
//! Every input chunk is applied in order. Content movement events describe actual
//! grid mutations, so consumers never need to simulate scrolling a second time.

use crate::cell::{self, Cell, CellStyle, Color, Link, Palette, Style};
use crate::grapheme::{self, Join};
use crate::parser::{Action, Csi, Input, Parser, StringKind, Terminator};
use crate::screen::{Cursor, Position, Row, Screen};
use base64::Engine;
use std::ops::Range;
use std::sync::Arc;
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

pub const MAX_CELLS: usize = 1_048_576;
pub const SYNC_TIMEOUT_MS: u64 = 150;
const MAX_SYNC_MEMORY: usize = 2 * 1024 * 1024;
/// Queue storage kept between synchronized frames; a larger frame releases its own.
const SYNC_RETAINED_ENTRIES: usize = 1024;
const SYNC_RETAINED_TEXT: usize = 64 * 1024;
/// Deferred CSI records kept for reuse, so their parameter storage is not reallocated.
const SYNC_SPARE_CSI: usize = 64;
/// ASCII bytes after a non-ASCII character that send a run back to the packed path.
const ASCII_HANDOFF: usize = 16;
/// Parameter vectors kept for reuse between recycled CSI records.
const SYNC_SPARE_PARAMS: usize = 256;

/// One synchronized-output queue entry. Printable text stays a run (a range of the
/// queue's text) so it replays through row writes when the update ends.
#[derive(Debug)]
enum Deferred {
    Text(std::ops::Range<usize>),
    Csi(Csi),
    /// A C0 control, the deferred `Action::Control`.
    Control(u8),
    Action(Action),
}

/// Synchronized output held until mode 2026 ends, a timeout or the memory bound.
/// Boxed so the terminal's own layout does not grow with the queue's buffers.
#[derive(Debug, Default)]
struct SyncQueue {
    entries: Vec<Deferred>,
    text: String,
    /// Bytes charged against `MAX_SYNC_MEMORY`, at the scalar-action rate.
    bytes: usize,
    spare_csi: Vec<Csi>,
    /// Parameter vectors released when a recycled record held more parameters than the
    /// sequence copied into it, reused when one holds fewer.
    spare_params: Vec<Vec<Option<u16>>>,
}

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

/// One prepared presentation for a style and hyperlink, so a print run or a scalar
/// write reuses a packed template instead of repacking and reallocating it.
///
/// Slots are keyed on the *inputs* (the full `Style` and the hyperlink's identity), so a
/// cached template can never go stale: every SGR attribute/colour change, OSC 8
/// open/close/change, soft reset, RIS and alternate-screen switch simply stops matching.
/// A slot's side record never holds combining marks: it is shared by reference and
/// `Cell::push_combining` always detaches through `Arc::make_mut` because the slot keeps
/// one reference.
#[derive(Clone, Debug)]
struct StyleCache {
    style: Style,
    link: Option<Arc<Link>>,
    template: CellStyle,
}

/// Prepared presentations retained per terminal. Programs cycle through a handful of
/// styles (a theme colour, the reset style, a truecolor accent measured per line), so a
/// few slots stop the common alternating pattern from rebuilding — and reallocating a
/// side record — on every style change. The footprint is fixed: at most this many
/// templates and their side records exist per terminal, all shared with live cells.
const STYLE_SLOTS: usize = 4;

/// Cluster analyses retained per terminal.
///
/// Program output repeats the same emoji families, regional-indicator flags and marked
/// letters, and every repeat otherwise pays an exact `unicode_segmentation` walk plus a
/// `UnicodeWidthStr` measure of the same bytes. A slot remembers both answers for one
/// complete candidate cluster, so it is independent of style, cursor and columns: only
/// the column clamp depends on those, and it is applied after every read.
const CLUSTER_SLOTS: usize = 16;

/// Largest key a slot holds: a lead character, at most `cell::MAX_COMBINING` marks and
/// the incoming character, each at most four UTF-8 bytes. Anything longer is simply not
/// remembered, which keeps the footprint fixed and every key naturally bounded.
const CLUSTER_KEY_BYTES: usize = 4 * (cell::MAX_COMBINING + 2);

/// One remembered exact analysis of a candidate cluster.
#[derive(Clone, Copy, Debug)]
struct ClusterAnalysis {
    key_len: u8,
    key: [u8; CLUSTER_KEY_BYTES],
    /// `UnicodeWidthStr::width` of the whole cluster before the column clamp. A cluster
    /// is a lead plus at most `MAX_COMBINING` marks plus one character, so the value is
    /// far below the stored maximum and never saturates.
    width: u16,
    /// Whether exact segmentation keeps the candidate in one cluster.
    joins: bool,
}

#[derive(Default)]
struct RunWrite {
    bytes: usize,
    join: Option<Join>,
}

#[derive(Debug)]
pub struct Terminal {
    parser: Parser,
    main: Screen,
    alternate: Screen,
    pub modes: Modes,
    pub palette: Palette,
    /// Private so every change passes a site that clears `current_template`.
    style: Style,
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
    sync: Box<SyncQueue>,
    grapheme_supported: bool,
    grapheme_target: Option<Position>,
    cluster_scratch: String,
    /// The cell whose complete cluster text `cluster_scratch` holds: its position, row
    /// id and row generation. Every cell write advances the generation and a recycled
    /// row gets a new id, so a match means the text is still the cell's.
    cluster_scratch_at: Option<(Position, u64, u64)>,
    /// The bounded set of remembered cluster analyses (see `ClusterAnalysis`), with the
    /// next slot to overwrite.
    cluster_cache: [Option<ClusterAnalysis>; CLUSTER_SLOTS],
    cluster_slot: usize,
    /// The bounded set of prepared templates allowed for this terminal (see
    /// `StyleCache`), with the next slot to overwrite.
    style_cache: [Option<StyleCache>; STYLE_SLOTS],
    style_slot: usize,
    /// The `style_cache` slot holding the template for the current style and
    /// hyperlink, cleared by every site that changes either (`style_changed`). Only
    /// `slot_template` replaces a slot, and it sets this to the slot it fills.
    current_slot: Option<usize>,
    /// Number of templates built, for tests that prove reuse.
    #[cfg(test)]
    template_builds: usize,
    pub preserve_erased_screen: bool,
    pub title_max_bytes: usize,
    pub title_max_chars: usize,
}

/// The length of the leading bytes below 0x80, eight at a time.
fn ascii_prefix(bytes: &[u8]) -> usize {
    let mut length = 0;
    while let Some(word) = bytes.get(length..length + 8) {
        let word = u64::from_le_bytes(word.try_into().expect("eight bytes"));
        let high = word & 0x8080_8080_8080_8080;
        if high != 0 {
            return length + (high.trailing_zeros() / 8) as usize;
        }
        length += 8;
    }
    length + bytes[length..].iter().take_while(|byte| byte.is_ascii()).count()
}

/// The length of the leading single-column cells, checked eight at a time without an
/// early exit inside each group so the check needs no per-cell branch.
/// How many of the `ascii` cells from `col` of `row`, which starts before the row's
/// blank certificate, are single-column, and the row's single-column certificate
/// before the store.
#[inline(never)]
fn overwrite_prefix(row: &Row, col: usize, ascii: usize) -> (usize, Option<usize>) {
    let prior = row.single_end();
    let checked = (col + ascii).min(row.blank_from());
    let known = prior.clamp(col, checked);
    debug_assert_eq!(single_width_prefix(&row.cells[col..known]), known - col);
    let scanned = single_width_prefix(&row.cells[known..checked]);
    (if known + scanned == checked { ascii } else { known + scanned - col }, Some(prior))
}

fn single_width_prefix(cells: &[Cell]) -> usize {
    let mut length = 0;
    for group in cells.as_chunks::<8>().0 {
        if !group.iter().fold(true, |all, cell| all & (cell.width() == 1)) {
            break;
        }
        length += 8;
    }
    length + cells[length..].iter().take_while(|cell| cell.width() == 1).count()
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
            sync: Box::default(),
            grapheme_supported: false,
            grapheme_target: None,
            cluster_scratch: String::new(),
            cluster_scratch_at: None,
            cluster_cache: [None; CLUSTER_SLOTS],
            cluster_slot: 0,
            style_cache: [None, None, None, None],
            style_slot: 0,
            current_slot: None,
            #[cfg(test)]
            template_builds: 0,
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
        // Exact synchronized-output ends (`ESC [ ? 2026 l`) in this chunk, counted when
        // first needed, and how many of them have been dispatched so far.
        let mut sync_ends: Option<usize> = None;
        let mut sync_ends_seen = 0usize;
        parser.feed_runs(bytes, |input| match input {
            Input::Text(text, ascii) => self.print_run(text, ascii, &mut emit),
            Input::Csi(csi) => {
                let sync_control = csi.prefix == Some(b'?') && csi.intermediates.is_empty()
                    && matches!(csi.final_byte, b'h' | b'l')
                    && csi.params.iter().any(|p| p.first() == Some(&Some(2026)));
                if sync_control && csi.params.len() == 1 {
                    // Start (or re-arm) or end synchronized output, as `dispatch` does,
                    // without taking the parser's parameter storage.
                    if csi.final_byte == b'h' {
                        // A frame that also ends in this chunk is applied as it arrives.
                        // The host cannot look at the terminal inside one `feed`, and
                        // queued actions replay with synchronized output already off, in
                        // order, so the result and every event are the same. Every
                        // literal end parses as one (ESC always starts a new sequence),
                        // so ends ahead are the chunk's ends less those dispatched; an
                        // end the count misses (eight-bit, or begun in an earlier chunk)
                        // only makes the frame queue. With a frame already queued from an
                        // earlier chunk, skipping the re-arm is equally unobservable: that
                        // end flushes the queue before anything reads the deadline.
                        let frame_closes =
                            *sync_ends.get_or_insert_with(|| count_sync_ends(bytes)) > sync_ends_seen;
                        if !frame_closes {
                            self.sync_deadline = Some(now_ms.saturating_add(SYNC_TIMEOUT_MS));
                        }
                    } else {
                        if csi.params[0].len() == 1 {
                            sync_ends_seen += 1;
                        }
                        self.flush_sync(&mut emit);
                    }
                } else if sync_control {
                    self.dispatch(Action::Csi(std::mem::take(csi)), now_ms, &mut emit);
                } else if self.sync_deadline.is_some() {
                    self.defer_csi(csi, &mut emit);
                } else {
                    self.grapheme_target = None;
                    self.csi(csi, &mut emit);
                }
            }
            // Outside synchronized output a control is applied at once, as `dispatch`
            // would, without the general action path.
            Input::Control(byte) | Input::Action(Action::Control(byte)) => {
                if self.sync_deadline.is_some() {
                    self.defer_control(byte, &mut emit);
                } else {
                    self.grapheme_target = None;
                    self.control(byte, &mut emit);
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
        self.sync.bytes = 0;
        if self.sync.entries.is_empty() {
            return;
        }
        // Deferred text replays as whole runs, so a synchronized frame takes the same
        // row writes as unsynchronized output instead of one dispatch per character.
        let mut entries = std::mem::take(&mut self.sync.entries);
        let mut text = std::mem::take(&mut self.sync.text);
        for entry in entries.drain(..) {
            match entry {
                Deferred::Text(range) => self.print_run(&text[range], false, emit),
                Deferred::Csi(csi) => {
                    self.grapheme_target = None;
                    self.csi(&csi, emit);
                    if self.sync.spare_csi.len() < SYNC_SPARE_CSI {
                        self.sync.spare_csi.push(csi);
                    }
                }
                Deferred::Control(byte) => {
                    self.grapheme_target = None;
                    self.control(byte, emit);
                }
                Deferred::Action(action) => self.apply(action, emit),
            }
        }
        // Keep an ordinary frame's storage for the next update. A frame that grew
        // toward the queue bound releases it instead of pinning it.
        text.clear();
        if entries.capacity() <= SYNC_RETAINED_ENTRIES && text.capacity() <= SYNC_RETAINED_TEXT {
            self.sync.entries = entries;
            self.sync.text = text;
        }
    }
    /// Queue printable text during synchronized output. Each character is charged the
    /// size of the scalar action it stands for, so the memory bound is reached on the
    /// same run as with a per-character queue. Where the flush falls inside that run is
    /// not observable: the run's characters print in order either way. Kept out of
    /// line so the unsynchronized run writer in `print_text` stays small.
    #[inline(never)]
    fn defer_text(&mut self, text: &str, emit: &mut impl FnMut(Event)) {
        let queue = &mut *self.sync;
        let start = queue.text.len();
        queue.text.push_str(text);
        let end = queue.text.len();
        match queue.entries.last_mut() {
            Some(Deferred::Text(range)) if range.end == start => range.end = end,
            _ => queue.entries.push(Deferred::Text(start..end)),
        }
        let chars = text.chars().count();
        queue.bytes += chars * std::mem::size_of::<Action>();
        if queue.bytes >= MAX_SYNC_MEMORY {
            self.flush_sync(emit);
        }
    }
    /// Queue a C0 control during synchronized output, charged as `dispatch` charges
    /// an `Action::Control`.
    #[inline(never)]
    fn defer_control(&mut self, byte: u8, emit: &mut impl FnMut(Event)) {
        let queue = &mut *self.sync;
        queue.bytes += std::mem::size_of::<Action>();
        queue.entries.push(Deferred::Control(byte));
        if queue.bytes >= MAX_SYNC_MEMORY {
            self.flush_sync(emit);
        }
    }
    /// Queue a CSI during synchronized output, charged exactly as `dispatch` charges an
    /// `Action::Csi`. The parser keeps its parameter storage: the sequence is copied
    /// into a recycled record instead of being taken.
    #[inline(never)]
    fn defer_csi(&mut self, csi: &Csi, emit: &mut impl FnMut(Event)) {
        let queue = &mut *self.sync;
        let mut owned = queue.spare_csi.pop().unwrap_or_default();
        owned.prefix = csi.prefix;
        owned.final_byte = csi.final_byte;
        owned.intermediates.clone_from(&csi.intermediates);
        // Match the parameter count from the pool first, so `clone_from` reuses every
        // vector instead of dropping or allocating one.
        while owned.params.len() > csi.params.len() {
            let released = owned.params.pop().expect("longer than the source");
            if queue.spare_params.len() < SYNC_SPARE_PARAMS {
                queue.spare_params.push(released);
            }
        }
        while owned.params.len() < csi.params.len() {
            owned.params.push(queue.spare_params.pop().unwrap_or_default());
        }
        owned.params.clone_from(&csi.params);
        queue.bytes += std::mem::size_of::<Action>()
            + csi.params.iter().map(|p| p.len() * std::mem::size_of::<Option<u16>>()).sum::<usize>();
        queue.entries.push(Deferred::Csi(owned));
        if queue.bytes >= MAX_SYNC_MEMORY {
            self.flush_sync(emit);
        }
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
            self.sync.bytes += std::mem::size_of::<Action>()
                + match &action {
                    Action::String { payload, .. } => payload.len(),
                    Action::Csi(csi) => csi
                        .params
                        .iter()
                        .map(|p| p.len() * std::mem::size_of::<Option<u16>>())
                        .sum(),
                    _ => 0,
                };
            self.sync.entries.push(Deferred::Action(action));
            if self.sync.bytes >= MAX_SYNC_MEMORY {
                self.flush_sync(emit);
            }
        } else {
            self.apply(action, emit);
        }
    }
    /// A C0 control, as `apply(Action::Control(byte))` performs it after clearing the
    /// grapheme target.
    fn control(&mut self, byte: u8, emit: &mut impl FnMut(Event)) {
        match byte {
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
        }
    }
    fn apply(&mut self, action: Action, emit: &mut impl FnMut(Event)) {
        if !matches!(&action, Action::Print(_)) {
            self.grapheme_target = None;
        }
        match action {
            Action::Print(ch) => self.print(ch, emit),
            Action::Control(byte) => self.control(byte, emit),
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
        let width = self.screen().rows[row].cells[col].width();
        self.clear_wide(row, col, bg, width);
    }
    /// Clear the cell at `col` and the other half of a glyph `width` columns wide. A
    /// caller that has already taken the cell out of the grid passes the width it holds,
    /// because the slot no longer describes the glyph that occupied it.
    fn clear_wide(&mut self, row: usize, col: usize, bg: Color, width: u8) {
        let cols = self.cols();
        let line = &mut self.screen_mut().rows[row];
        // One blank per repair, so an RGB background shares one side record instead of
        // allocating one per cleared cell. `put_blank` keeps the row's heap flag honest.
        let spacer = width == 0 && col > 0;
        let tail = width == 2 && col + 1 < cols;
        line.record_write(col + 1 + usize::from(tail), 1);
        if spacer {
            line.put_blank(col - 1, bg);
        }
        if tail {
            line.put_blank(col + 1, bg);
        }
        line.put_blank(col, bg);
    }
    /// Write printable text a row at a time. Each run prepares one presentation
    /// template and writes the cells in a single pass, so an ordinary character costs
    /// one cell store instead of a full scalar dispatch. Synchronized output queues the
    /// whole run instead. Anything protocol-sensitive stays on the scalar path one
    /// character at a time: insert mode, character-set translation, a pending wrap,
    /// wide-cell repair, a combining mark, or a possible grapheme join.
    /// `ascii` promises that `text` is all ASCII; `false` promises nothing.
    fn print_text(&mut self, mut text: &str, ascii: bool, emit: &mut impl FnMut(Event)) {
        if text.is_empty() {
            return;
        }
        if self.sync_deadline.is_some() {
            self.defer_text(text, emit);
            return;
        }
        // A printable run cannot change the style or the hyperlink — it only ever
        // dispatches `Print` — so one presentation serves every chunk this run writes.
        let template = self.style_template();
        while !text.is_empty() {
            let scalar = self.modes.insert
                || self.single_shift.is_some()
                || self.charsets[self.charset];
            let written = if scalar { RunWrite::default() } else { self.write_run(text, ascii, &template) };
            text = &text[written.bytes..];
            if let Some(verdict) = written.join {
                let ch = text.chars().next().expect("join stops inside the run");
                self.print_with_verdict(ch, Some(verdict), emit);
                text = &text[ch.len_utf8()..];
                // A cluster usually continues (modifiers, joiners, the second regional
                // indicator), so characters up to the next simple one go straight to
                // the scalar path instead of setting up another run for each.
                while let Some(ch) = text.chars().next() {
                    if grapheme::simple_width(ch).is_some() {
                        break;
                    }
                    self.print(ch, emit);
                    text = &text[ch.len_utf8()..];
                }
                continue;
            }
            if written.bytes != 0 {
                continue;
            }
            // Synchronized output was ruled out above, so this is `apply(Print)`.
            let ch = text.chars().next().expect("non-empty text");
            self.print(ch, emit);
            text = &text[ch.len_utf8()..];
        }
    }
    /// Write a parser-validated printable run. `Input::Text` is already a `&str`, so no
    /// whole-run UTF-8 validation happens here.
    fn print_run(&mut self, text: &str, ascii: bool, emit: &mut impl FnMut(Event)) {
        self.print_text(text, ascii, emit);
    }
    /// The prepared presentation for the current style and hyperlink, rebuilt only when
    /// both are absent from the bounded slot set. At most `STYLE_SLOTS` templates are
    /// retained per terminal.
    fn style_template(&mut self) -> CellStyle {
        if let Some(slot) = self.current_slot
            && let Some(cache) = &self.style_cache[slot]
        {
            let template = &cache.template;
            debug_assert!(
                template.same_presentation(&CellStyle::new(&self.style, self.link.as_ref())),
                "a style or hyperlink change missed style_changed"
            );
            return template.clone();
        }
        self.slot_template()
    }
    /// The current style or hyperlink may have changed.
    fn style_changed(&mut self) {
        self.current_slot = None;
    }
    fn slot_template(&mut self) -> CellStyle {
        let style = self.style;
        let link = self.link.as_ref();
        for (index, slot) in self.style_cache.iter().enumerate() {
            let Some(cache) = slot else { continue };
            if cache.style == style
                && match (&cache.link, link) {
                    (Some(cached), Some(current)) => Arc::ptr_eq(cached, current),
                    (None, None) => true,
                    _ => false,
                }
            {
                self.current_slot = Some(index);
                return cache.template.clone();
            }
        }
        let template = CellStyle::new(&style, link);
        self.current_slot = Some(self.style_slot % STYLE_SLOTS);
        self.style_cache[self.style_slot % STYLE_SLOTS] = Some(StyleCache {
            style,
            link: link.cloned(),
            template: template.clone(),
        });
        self.style_slot = (self.style_slot + 1) % STYLE_SLOTS;
        #[cfg(test)]
        {
            self.template_builds += 1;
        }
        template
    }
    /// Templates built so far; a reuse regression shows up as a growing count.
    #[cfg(test)]
    fn template_builds_for_test(&self) -> usize {
        self.template_builds
    }
    /// Write the leading characters of `text` that this row can take in place. A join
    /// verdict belongs to the first unconsumed character, so its caller need not classify
    /// the same pair again on the scalar path.
    ///
    /// A printable ASCII prefix over single-column cells — the ordinary case — is one
    /// store per byte against a prepared packed word. Everything else (wide glyphs,
    /// combining marks, possible grapheme joins, hyperlinks and presentations with a
    /// side record) goes through the per-character loop below, which applies exactly
    /// the checks `print` applies.
    fn write_run(&mut self, text: &str, all_ascii: bool, template: &CellStyle) -> RunWrite {
        debug_assert!(!all_ascii || text.is_ascii());
        let cols = self.cols();
        let cursor = self.screen().cursor;
        // A pending wrap must go through `print`, which marks the row as wrapped and
        // moves the cursor before any cell is written.
        if cursor.pending_wrap {
            return RunWrite::default();
        }
        let pos = cursor.position;
        if self.plain_ascii_run_start(text) {
            let span = (cols - pos.col).min(text.len());
            // A text run holds printable ASCII and whole multi-byte scalars only, so its
            // ASCII prefix ends at the first byte with the high bit set.
            let ascii = if all_ascii { span } else { ascii_prefix(&text.as_bytes()[..span]) };
            if ascii > 0 {
                let line = &self.screen().rows[pos.row];
                // Cells past the blank certificate are single-column blanks already.
                // Over older cells, those before the single-column certificate need no
                // check either, and the store extends the certificate; a store over
                // blanks leaves it to lapse, so a rewritten row earns it on its first
                // rewrite.
                let (count, prior) =
                    if pos.col >= line.blank_from() { (ascii, None) } else { overwrite_prefix(line, pos.col, ascii) };
                if count > 0 {
                    let packed = template.packed_written_column();
                    let side_data = template.has_side_data();
                    let screen = self.screen_mut();
                    let row = &mut screen.rows[pos.row];
                    let heap_free = row.heap_free();
                    row.record_write(pos.col + count, count as u64);
                    if let Some(prior) = prior {
                        row.note_single(prior, pos.col, pos.col + count);
                    }
                    let bytes = &text.as_bytes()[..count];
                    let cells = &mut row.cells[pos.col..pos.col + count];
                    if side_data {
                        // One reference bump per cell instead of one allocation.
                        for (cell, &byte) in cells.iter_mut().zip(bytes) {
                            *cell = template.written_column(char::from(byte));
                        }
                        row.mark_heap();
                    } else if heap_free {
                        // No old cell owns heap, so the stores need no destructor.
                        Cell::store_ascii_heap_free(cells, bytes, packed);
                    } else {
                        for (cell, &byte) in cells.iter_mut().zip(bytes) {
                            *cell = Cell::from_packed(char::from(byte), packed);
                        }
                    }
                    row.charge_write(pos.col, count, template.side_identity());
                    let end = pos.col + count;
                    screen.cursor.position.col = end.min(cols - 1);
                    screen.cursor.pending_wrap = end >= cols;
                    self.last_printed = Some(char::from(bytes[count - 1]));
                    self.grapheme_target = Some(Position { row: pos.row, col: end - 1 });
                    return RunWrite { bytes: count, join: None };
                }
            }
        }
        self.write_run_cells(text, pos, cols, template)
    }
    /// One character at a time, for everything the batched prefix cannot take.
    #[allow(clippy::too_many_lines)]
    fn write_run_cells(&mut self, text: &str, pos: Position, cols: usize, template: &CellStyle) -> RunWrite {
        let graphemes = self.modes.grapheme_clusters;
        // Only the cell recorded before the run can hold a cluster to join into.
        let target = self.grapheme_target;
        let mut col = pos.col;
        let mut bytes = 0;
        let mut join = None;
        let mut previous: Option<char> = None;
        // The class `previous` got when the pair rules last looked at it, carried so a
        // character is classified once instead of once as `next` and again as the tail
        // of the following pair. `None` means the pair was an ordinary ASCII pair that
        // needed no decision, and the class is filled in when one is needed.
        let mut previous_class: Option<grapheme::Classes> = None;
        // Whether the character written before this one is a `simple_width` character.
        let mut previous_simple = false;
        let mut last_col = pos.col;
        let mut last_char = ' ';
        // Without a side record the cells are built from packed words, and over a row
        // whose cells own no heap they are stored without running a destructor.
        let plain = template.plain_words();
        let screen = self.screen_mut();
        let row = &mut screen.rows[pos.row];
        let heap_free = row.heap_free();
        for ch in text.chars() {
            // A simple character never joins the simple character written before it
            // (ordinary ASCII, Latin text, CJK, kana and Hangul syllables), so such text
            // does no grapheme work at all.
            let simple = grapheme::simple_width(ch);
            let mut carried = None;
            if graphemes && !(previous_simple && simple.is_some()) {
                let verdict = match previous {
                    Some(lead) => {
                        let tail = previous_class.unwrap_or_else(|| grapheme::classes(lead));
                        let next = grapheme::classes(ch);
                        carried = Some(next);
                        grapheme::join_classes(tail, next, lead, &[])
                    }
                    None => match target {
                        Some(position)
                            if position.row == pos.row
                                && row.cells[position.col].width() != 0 =>
                        {
                            let cell = &row.cells[position.col];
                            let next = grapheme::classes(ch);
                            carried = Some(next);
                            let tail = cell.combining().last().copied().unwrap_or(cell.ch);
                            grapheme::join_classes(
                                grapheme::classes(tail),
                                next,
                                cell.ch,
                                cell.combining(),
                            )
                        }
                        Some(_) => Join::Unknown,
                        None => Join::No,
                    },
                };
                // A run writes every character into its own cell and remembers only the
                // one it wrote last. Anything whose cluster membership depends on more
                // than that pair — a mark, a joiner, a regional indicator, a jamo, a
                // pictograph after a ZWJ, or an unmodelled script — reports `Yes` or
                // `Unknown` when it arrives, so it breaks to `print`, which decides from
                // the complete cluster stored in the cell.
                if verdict != Join::No {
                    join = Some(verdict);
                    break;
                }
            }
            let width = if let Some(width) = simple {
                usize::from(width).min(cols)
            } else {
                carried
                    .and_then(grapheme::Classes::width)
                    .map_or_else(|| char_width(ch, cols), |width| width.min(cols))
            };
            if width == 0 || col + width > cols {
                break;
            }
            let contained = if width == 1 {
                row.cells[col].width() == 1
            } else {
                row.cells[col].width() != 0 && row.cells[col + 1].width() != 2
            };
            if !contained {
                break;
            }
            if let Some(words) = plain {
                let cells = &mut row.cells[col..col + width];
                let lead = Cell::from_packed(ch, words[width - 1]);
                if heap_free {
                    cells[0].store_heap_free(lead);
                    if width == 2 {
                        cells[1].store_heap_free(Cell::from_packed(' ', words[2]));
                    }
                } else {
                    cells[0] = lead;
                    if width == 2 {
                        cells[1] = Cell::from_packed(' ', words[2]);
                    }
                }
            } else {
                row.cells[col] = template.cell(ch, width as u8, true);
                if width == 2 {
                    let spacer = row.cells[col].spacer();
                    row.cells[col + 1] = spacer;
                }
            }
            last_col = col;
            last_char = ch;
            col += width;
            bytes += ch.len_utf8();
            previous = Some(ch);
            previous_class = carried;
            previous_simple = simple.is_some();
            // After a non-ASCII character, a long ASCII stretch returns to the caller so
            // the packed ASCII path writes it; a short one stays here, where switching
            // would cost more than it saves. Plain ASCII never joins a non-ASCII
            // character before it.
            if !ch.is_ascii()
                && let Some(&next) = text.as_bytes()[bytes..].first_chunk::<ASCII_HANDOFF>()
                && u128::from_ne_bytes(next) & u128::from_ne_bytes([0x80; ASCII_HANDOFF]) == 0
            {
                break;
            }
        }
        if bytes != 0 {
            let advance = col - pos.col;
            row.record_write(col, advance as u64);
            row.charge_write(pos.col, advance, template.side_identity());
            if template.has_side_data() {
                row.mark_heap();
            }
            screen.cursor.position.col = col.min(cols - 1);
            screen.cursor.pending_wrap = col >= cols;
            self.last_printed = Some(last_char);
            self.grapheme_target = Some(Position { row: pos.row, col: last_col });
        }
        RunWrite { bytes, join }
    }
    /// Whether the first character of `text` is certain to start a new cluster instead
    /// of joining the cell recorded before this run.
    fn plain_ascii_run_start(&self, text: &str) -> bool {
        let Some(position) = self.grapheme_target else {
            return true;
        };
        let Some(ch) = text.chars().next() else {
            return false;
        };
        if !ch.is_ascii() {
            return false;
        }
        if !self.modes.grapheme_clusters {
            return true;
        }
        let cursor = self.screen().cursor;
        if position.row != cursor.position.row {
            return false;
        }
        let cell = &self.screen().rows[position.row].cells[position.col];
        if cell.width() == 0 {
            return false;
        }
        if cell.ch.is_ascii() && cell.combining_len() == 0 && ch.is_ascii() {
            return true;
        }
        grapheme::join(cell.ch, cell.combining(), ch) == Join::No
    }
    fn print(&mut self, ch: char, emit: &mut impl FnMut(Event)) {
        self.print_with_verdict(ch, None, emit);
    }
    fn print_with_verdict(&mut self, mut ch: char, verdict: Option<Join>, emit: &mut impl FnMut(Event)) {
        let charset = self.single_shift.take().unwrap_or(self.charset);
        if self.charsets[charset] {
            ch = dec_graphic(ch);
        }
        if self.modes.grapheme_clusters && self.join_grapheme(ch, verdict, emit) {
            return;
        }
        let width = ch.width().unwrap_or(0).min(2).min(self.cols());
        if width == 0 {
            let cursor = self.screen().cursor;
            let mut col = cursor.position.col;
            if !cursor.pending_wrap {
                col = col.saturating_sub(1);
            }
            let screen = self.screen_mut();
            let row = &mut screen.rows[cursor.position.row];
            if row.cells[col].width() == 0 {
                col = col.saturating_sub(1);
            }
            if row.cells[col].push_combining_from(ch, &mut screen.pool) {
                row.record_full_write(1);
                row.cells[col].set_written(true);
                row.mark_heap();
                // The cell now owns a detached record, so the row must recount.
                row.charge_unknown();
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
        let contained = if width == 1 {
            cells[pos.col].width() == 1
        } else {
            cells[pos.col].width() != 0 && cells[pos.col + 1].width() != 2
        };
        if contained {
            // Only the cells this character takes change, so the blank certificate
            // past them still holds.
            self.screen_mut().rows[pos.row].record_write(pos.col + width, width as u64);
        } else {
            self.clear_wide_at(pos.row, pos.col, self.style.bg);
            if width == 2 {
                self.clear_wide_at(pos.row, pos.col + 1, self.style.bg);
            }
        }
        let template = self.style_template();
        let row = &mut self.screen_mut().rows[pos.row];
        row.cells[pos.col] = template.cell(ch, width as u8, true);
        if width == 2 {
            let spacer = row.cells[pos.col].spacer();
            row.cells[pos.col + 1] = spacer;
        }
        if template.has_side_data() {
            row.mark_heap();
        }
        row.charge_write(pos.col, width, template.side_identity());
        let cols = self.cols();
        let cursor = &mut self.screen_mut().cursor;
        cursor.position.col = (pos.col + width).min(cols - 1);
        cursor.pending_wrap = pos.col + width >= cols;
        self.last_printed = Some(ch);
        self.grapheme_target = Some(pos);
    }
    fn join_grapheme(&mut self, ch: char, verdict: Option<Join>, emit: &mut impl FnMut(Event)) -> bool {
        let Some(mut position) = self.grapheme_target else {
            return false;
        };
        // Character properties answer the boundary question for ordinary pairs; the
        // candidate cluster is still built below because a cluster's column width is
        // not a sum of character widths (emoji sequences and variation selectors).
        let verdict = match verdict {
            Some(verdict) => verdict,
            None => {
                let previous = &self.screen().rows[position.row].cells[position.col];
                if ch.is_ascii() && previous.ch.is_ascii() && previous.combining_len() == 0 {
                    return false;
                }
                if previous.width() == 0 {
                    Join::Unknown
                } else {
                    grapheme::join(previous.ch, previous.combining(), ch)
                }
            }
        };
        if verdict == Join::No {
            return false;
        }
        // Build the candidate cluster in a reused buffer instead of allocating a fresh
        // String for every printed non-ASCII character. It is moved back out below and
        // restored on every early return.
        let mut cluster = std::mem::take(&mut self.cluster_scratch);
        let remembered = self.cluster_scratch_at.take();
        {
            let row = &self.screen().rows[position.row];
            let previous = &row.cells[position.col];
            if remembered == Some((position, row.id, row.generation)) {
                debug_assert_eq!(
                    cluster,
                    if previous.width() != 0 { previous.text() } else { String::new() },
                    "the remembered cluster is the cell's"
                );
            } else {
                cluster.clear();
                if previous.width() != 0 {
                    cluster.push(previous.ch);
                    cluster.extend(previous.combining());
                }
            }
            cluster.push(ch);
        }
        // Programs repeat the same families, flags and marked letters, so the exact
        // analysis of the complete candidate is remembered and reused verbatim.
        let cached = self.cluster_analysis(&cluster);
        if verdict == Join::Unknown {
            let joins = match cached {
                Some((joins, _)) => joins,
                None => {
                    let joins = cluster.graphemes(true).nth(1).is_none();
                    if !joins {
                        self.remember_cluster(&cluster, false, 0);
                        self.cluster_scratch = cluster;
                        return false;
                    }
                    joins
                }
            };
            if !joins {
                // A remembered break settles it without walking the segmentation again,
                // and reaches exactly the answer the exact rules gave the first time.
                self.cluster_scratch = cluster;
                return false;
            }
        }
        if self.screen().rows[position.row].cells[position.col].combining_len() >= cell::MAX_COMBINING {
            self.cluster_scratch = cluster;
            return true;
        }
        let old_width = self.screen().rows[position.row].cells[position.col].width();
        // The remembered width is the unclamped `UnicodeWidthStr` measure; the column
        // clamp below is the only part of the decision that depends on this terminal.
        let measured = match cached {
            Some((_, width)) => width,
            None => {
                let width = cluster.width();
                self.remember_cluster(&cluster, true, width);
                width
            }
        };
        let mut width = measured.clamp(1, 2).min(self.cols());
        // DECAWM off: keep the cluster inside the last column instead of
        // wrapping and advancing a row (print() clamps the same way).
        if position.col + width > self.cols() && !self.modes.wrap {
            width = self.cols() - position.col;
        }
        if width == usize::from(old_width) && position.col + width <= self.cols() {
            self.cluster_scratch = cluster;
            let screen = self.screen_mut();
            let row = &mut screen.rows[position.row];
            let appended = row.cells[position.col].push_combining_from(ch, &mut screen.pool);
            debug_assert!(appended, "the combining bound was checked above");
            row.record_write(position.col + width, 1);
            row.mark_heap();
            row.charge_unknown();
            self.cluster_scratch_at = Some((position, row.id, row.generation));
            self.grapheme_target = Some(position);
            self.last_printed = Some(ch);
            return true;
        }
        // Width changes and wrapping still need the complete wide-cell repair. Take the
        // cell instead of cloning it so its combining record can grow in place.
        let mut cell = std::mem::take(&mut self.screen_mut().rows[position.row].cells[position.col]);
        let bg = cell.style().bg;
        self.cluster_scratch = cluster;
        cell.push_combining_from(ch, &mut self.screen_mut().pool);
        cell.set_width(width as u8);
        if position.col + width > self.cols() {
            self.clear_wide(position.row, position.col, bg, old_width);
            self.screen_mut().rows[position.row].wrapped = true;
            self.screen_mut().rows[position.row].wrap_padding = true;
            self.screen_mut().cursor.position.col = 0;
            self.linefeed(emit);
            position = self.cursor();
        }
        if width != usize::from(old_width) {
            self.clear_wide(position.row, position.col, bg, old_width);
            if width == 2 {
                self.clear_wide_at(position.row, position.col + 1, bg);
            }
        }
        let trail = (width == 2).then(|| cell.spacer());
        let row = &mut self.screen_mut().rows[position.row];
        row.record_write(position.col + width, 1);
        row.cells[position.col] = cell;
        if width == 2 {
            row.cells[position.col + 1] = trail.expect("a wide cluster has a trailing cell");
        }
        row.mark_heap();
        row.charge_unknown();
        self.cluster_scratch_at = Some((position, row.id, row.generation));
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
    /// The remembered exact analysis of `cluster`, if this terminal has seen it.
    fn cluster_analysis(&self, cluster: &str) -> Option<(bool, usize)> {
        let bytes = cluster.as_bytes();
        self.cluster_cache
            .iter()
            .flatten()
            .find(|slot| usize::from(slot.key_len) == bytes.len() && &slot.key[..bytes.len()] == bytes)
            .map(|slot| (slot.joins, usize::from(slot.width)))
    }
    /// Remember one exact analysis, replacing `cluster_slot` round-robin so the footprint
    /// stays fixed. A candidate longer than a key is not cached; the natural bound is a
    /// lead character plus `MAX_COMBINING` marks plus the incoming one.
    fn remember_cluster(&mut self, cluster: &str, joins: bool, width: usize) {
        let bytes = cluster.as_bytes();
        if bytes.len() > CLUSTER_KEY_BYTES {
            return;
        }
        let mut key = [0u8; CLUSTER_KEY_BYTES];
        key[..bytes.len()].copy_from_slice(bytes);
        let analysis = ClusterAnalysis {
            key_len: bytes.len() as u8,
            key,
            width: width.min(usize::from(u16::MAX)) as u16,
            joins,
        };
        let slot = self.cluster_slot;
        self.cluster_slot = (slot + 1) % CLUSTER_SLOTS;
        self.cluster_cache[slot] = Some(analysis);
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
        self.style_changed();
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
                row.cells.fill(Cell::plain('E'));
                // Alignment fill: no cell owns a side record any more.
                row.charge_plain();
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
    /// Erase whole rows to blanks of the current background. A row that already holds
    /// only such blanks, with no wrap state, would come out identical: it is left as it
    /// is, generation included, so a snapshot does not resend it.
    fn erase_rows(&mut self, rows: Range<usize>) {
        let bg = self.style.bg;
        for row in self.screen_mut().rows.range_mut(rows) {
            if row.is_blank(bg) && !row.wrapped && !row.wrap_padding {
                continue;
            }
            row.reset_cells(bg);
            row.generation = row.generation.wrapping_add(1);
            row.mark_blank(bg);
            row.wrapped = false;
            row.wrap_padding = false;
        }
    }
    fn erase(&mut self, row: usize, range: Range<usize>) {
        let cols = self.cols();
        let bg = self.style.bg;
        let start = range.start.min(cols);
        let end = range.end.min(cols);
        if start < end {
            if start == 0 && end == cols {
                self.erase_rows(row..row + 1);
                return;
            } else {
                self.clear_wide_at(row, start, bg);
                if end < cols && self.screen().rows[row].cells[end].width() == 0 {
                    self.clear_wide_at(row, end, bg);
                }
                let line = &mut self.screen_mut().rows[row];
                line.record_write(end, 0);
                line.fill_blank(start..end, bg);
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
                self.erase_rows(pos.row + 1..rows);
            }
            1 => {
                self.erase_rows(0..pos.row);
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
                self.erase_rows(0..rows);
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
        let bg = self.style.bg;
        // ICH, DCH and ECH edit in place; the next print must not wrap first.
        self.screen_mut().rows[pos.row].record_full_write(1);
        self.screen_mut().cursor.pending_wrap = false;
        if erase_only {
            self.erase(pos.row, pos.col..pos.col + count);
            return;
        }
        let row = &mut self.screen_mut().rows[pos.row];
        if insert {
            row.cells[pos.col..].rotate_right(count);
            row.fill_blank(pos.col..pos.col + count, bg);
        } else {
            row.cells[pos.col..].rotate_left(count);
            row.fill_blank(cols - count..cols, bg);
        }
        // Edits can split either boundary of a wide cell. Repair orphan halves; the
        // blank may own a side record (an RGB background), which `put_blank` records.
        for col in pos.col.saturating_sub(1)..cols {
            if row.cells[col].width() == 2 && (col + 1 == cols || row.cells[col + 1].width() != 0)
                || row.cells[col].width() == 0 && (col == 0 || row.cells[col - 1].width() != 2)
            {
                row.put_blank(col, bg);
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
            self.style_changed();
            self.modes.cursor_visible = true;
            self.charsets = [false; 4];
            self.charset = 0;
            self.single_shift = None;
            self.screen_mut().saved_cursor = Cursor::default();
            self.saved_state[usize::from(self.modes.alternate)] = SavedState::default();
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
        self.style_changed();
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
                    self.style_changed();
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
        self.cluster_scratch_at = None;
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
        self.style_changed();
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

/// Width of one printed character, matching the scalar path's clamp exactly.
#[inline]
/// The number of exact synchronized-output ends, `ESC [ ? 2026 l`, in `bytes`. The
/// search stops at each `?`, which is rarer than ESC in escape-dense output.
fn count_sync_ends(bytes: &[u8]) -> usize {
    let mut count = 0;
    let mut index = 2;
    while index < bytes.len() {
        let Some(offset) = find_byte(&bytes[index..], b'?') else { break };
        let at = index + offset;
        if bytes[at - 2..at] == *b"\x1b[" && bytes[at..].starts_with(b"?2026l") {
            count += 1;
        }
        index = at + 1;
    }
    count
}

/// The offset of the first `needle` in `bytes`, eight bytes at a time.
fn find_byte(bytes: &[u8], needle: u8) -> Option<usize> {
    const ONES: u64 = 0x0101_0101_0101_0101;
    const HIGH: u64 = 0x8080_8080_8080_8080;
    let (words, tail) = bytes.as_chunks::<8>();
    for (index, word) in words.iter().enumerate() {
        let diff = u64::from_le_bytes(*word) ^ (ONES * u64::from(needle));
        // The lowest flagged byte is exact: a borrow only reaches bytes above a zero.
        let zero = diff.wrapping_sub(ONES) & !diff & HIGH;
        if zero != 0 {
            return Some(index * 8 + (zero.trailing_zeros() / 8) as usize);
        }
    }
    tail.iter().position(|&byte| byte == needle).map(|offset| words.len() * 8 + offset)
}

fn char_width(ch: char, cols: usize) -> usize {
    if ch.is_ascii() {
        1
    } else {
        ch.width().unwrap_or(0).min(2).min(cols)
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
        feed_at(term, bytes, 0)
    }
    fn feed_at(term: &mut Terminal, bytes: &[u8], now: u64) -> Vec<Event> {
        let mut events = Vec::new();
        term.feed(bytes, now, |e| events.push(e));
        #[cfg(test)]
        for screen in [&term.main, &term.alternate] {
            for row in screen.rows.iter().chain(&screen.history) {
                row.assert_charge_matches_recount(std::str::from_utf8(bytes).unwrap_or("<bytes>"));
            }
        }
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
             scalar_queue(term), term.sync.bytes, term.grapheme_supported, term.grapheme_target),
            (&term.cluster_scratch, term.preserve_erased_screen, term.title_max_bytes, term.title_max_chars))
    }
    /// The synchronized queue as the per-character action list it stands for, so a
    /// run-holding queue compares equal to the scalar path's queue.
    fn scalar_queue(term: &Terminal) -> Vec<Action> {
        let mut actions = Vec::new();
        for entry in &term.sync.entries {
            match entry {
                Deferred::Text(range) => actions.extend(term.sync.text[range.clone()].chars().map(Action::Print)),
                Deferred::Csi(csi) => actions.push(Action::Csi(csi.clone())),
                Deferred::Control(byte) => actions.push(Action::Control(*byte)),
                Deferred::Action(action) => actions.push(action.clone()),
            }
        }
        actions
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

    /// Replay `corpus` into both terminals in chunks of `chunk` bytes, comparing events
    /// and complete state after every chunk.
    fn assert_corpus_matches_scalar(
        cols: usize,
        rows: usize,
        history: usize,
        graphemes: bool,
        corpus: &[&str],
        chunk: usize,
    ) {
        let mut fast = Terminal::new(cols, rows, history).unwrap();
        let mut scalar = Terminal::new(cols, rows, history).unwrap();
        fast.enable_grapheme_support(graphemes);
        scalar.enable_grapheme_support(graphemes);
        for (index, text) in corpus.iter().enumerate() {
            let now = index as u64;
            for part in text.as_bytes().chunks(chunk.max(1)) {
                assert_eq!(
                    feed_at(&mut fast, part, now),
                    feed_scalar(&mut scalar, part, now),
                    "cols={cols} rows={rows} history={history} graphemes={graphemes} chunk={chunk} text={text:?}"
                );
                assert_eq!(
                    state(&fast),
                    state(&scalar),
                    "cols={cols} rows={rows} history={history} graphemes={graphemes} chunk={chunk} text={text:?}"
                );
            }
        }
    }

    #[test]
    fn reused_side_records_carry_nothing_from_their_last_cell() {
        // Marked, linked and wide clusters scroll off and are blanked, so their records
        // are reused by the clusters written next, which must hold only their own marks.
        let mut term = Terminal::new(12, 2, 0).unwrap();
        term.enable_grapheme_support(true);
        let old = "\x1b]8;;https://example.invalid\x1b\\e\u{301}\u{302}\u{303}o\u{308}\x1b]8;;\x1b\\👩🏽\u{200d}💻🇯🇵\r\n";
        for _ in 0..4 {
            feed(&mut term, old.as_bytes());
        }
        assert!(term.main.pool.len() > 0, "blanking kept the records");
        feed(&mut term, "a\u{300}b\u{301}\u{302}🏳\u{fe0f}\r\n".as_bytes());
        let row = &term.screen().rows[0];
        assert_eq!(row.cells[0].text(), "a\u{300}");
        assert_eq!(row.cells[1].text(), "b\u{301}\u{302}");
        assert_eq!(row.cells[2].text(), "🏳\u{fe0f}");
        assert!(row.cells.iter().all(|cell| cell.link().is_none()));
        let mut reference = Terminal::new(12, 2, 0).unwrap();
        reference.enable_grapheme_support(true);
        feed(&mut reference, "\r\na\u{300}b\u{301}\u{302}🏳\u{fe0f}\r\n".as_bytes());
        let expected = &reference.screen().rows[0];
        for (cell, want) in row.cells.iter().zip(&expected.cells) {
            assert_eq!(format!("{cell:?}"), format!("{want:?}"));
        }
        for row in &term.screen().rows {
            row.assert_charge_matches_recount("after reuse");
        }
    }

    #[test]
    fn rewritten_rows_match_scalar_writes() {
        // The same rows rewritten in place, earning the single-column certificate,
        // then edited by every other kind of write before the next rewrite: wide
        // glyphs inside and past the certified columns, marks, inserts, deletes,
        // erases, wrapped first characters and partial rewrites that start past it.
        let corpus = [
            "\x1b[Habcdefghijkl\r\nmnopqrstuvwx",
            "\x1b[Habcdefghijkl\r\nmnopqrstuvwx",
            "\x1b[Habcdefghijkl\x1b[1;4H中\x1b[Habcdefghijkl",
            "\x1b[Habcdefghijkl\x1b[1;11H中\x1b[Habcdefghijkl",
            "\x1b[Habcdef\x1b[1;3He\u{301}\x1b[Habcdefghijkl",
            "\x1b[Habcdefghijkl\x1b[1;2H\x1b[2@中\x1b[Habcdefghijkl",
            "\x1b[Habcdefghijkl\x1b[1;2H\x1b[3P\x1b[Habcdefghijkl",
            "\x1b[Habcdefghijkl\x1b[1;5H\x1b[K\x1b[Habcdefghijkl",
            "\x1b[Habcdefghijkl\x1b[1;8Hxyz\x1b[1;4H中中\x1b[1;7Habcdefgh",
            "\x1b[1;9Habcd\x1b[Habcdefghijkl中\x1b[Habcdefghijkl",
            "\x1b[2;1Habcdefghijklmnopqrstuvwxyz\x1b[2;1Habcdefghijklmnop",
            "\x1b[Habcdefghijkl\x1b[1;1H\x1b[2J\x1b[Habcdefghijkl",
        ];
        for cols in [8usize, 12, 20] {
            for chunk in [1usize, 5, 256] {
                assert_corpus_matches_scalar(cols, 4, 4, true, &corpus, chunk);
            }
        }
        // A resize moves cells between rows without advancing their generations: rows
        // that earned the certificate receive wide glyphs from wrapped lines above.
        for (before, after) in [(12usize, 6usize), (6, 12), (12, 8), (8, 12)] {
            for setup in ["中中中中中中中中中中中中", "ab中cd中ef中gh中ij中kl中mn中", "abcdefgh中中中中中中中中"] {
                let mut fast = Terminal::new(before, 4, 0).unwrap();
                let mut scalar = Terminal::new(before, 4, 0).unwrap();
                for term in [&mut fast, &mut scalar] {
                    term.enable_grapheme_support(true);
                }
                let mut steps: Vec<Vec<u8>> = Vec::new();
                for row in 1..=4 {
                    for _ in 0..3 {
                        steps.push(format!("\x1b[{row};1Habcdefghijkl").into_bytes());
                    }
                }
                steps.push(format!("\x1b[H{setup}").into_bytes());
                for step in &steps {
                    feed(&mut fast, step);
                    feed_scalar(&mut scalar, step, 0);
                }
                fast.resize(after, 4, |_| {}).unwrap();
                scalar.resize(after, 4, |_| {}).unwrap();
                for row in 1..=4 {
                    let rewrite = format!("\x1b[{row};1Hxyzxyzxyzxyz\x1b[{row};1Hxyzxyzxyzxyz").into_bytes();
                    feed(&mut fast, &rewrite);
                    feed_scalar(&mut scalar, &rewrite, 0);
                }
                assert_eq!(state(&fast), state(&scalar), "{before} {after} {setup}");
            }
        }
    }

    #[test]
    fn text_runs_match_scalar_writes_across_unicode_shapes_and_narrow_grids() {
        // Ordinary text, wide glyphs, combining marks, ZWJ sequences, regional
        // indicators, escape-driven edits, insert mode and wrapping in narrow grids.
        let corpus = [
            "ordinary ascii text 0123456789 !~",
            "中文 日本語 한국어 e\u{301} 😀 👩🏽‍💻 🇯🇵 🇺🇸 text",
            "\u{600}abc1\u{fe0f}\u{20e3}xyz ❤\u{fe0f} 🏳️‍🌈",
            "\x1b[38;2;80;180;240mtruecolor run\x1b[0m plain",
            "\x1b[4:3;58;5;9munderlined\x1b[59m\x1b[24m",
            "\x1b[4hinsert\x1b[4l\x1b[2@\x1b[2P\x1b[2X",
            "\x1b[1;3H中中\x1b[1;2Hwide repair\x1b[1;1H中",
            "\x1b[?7lnarrow margins\x1b[?7h",
            "\x1b[?1049halt screen 中\r\nsecond\x1b[?1049lback",
            "\x1b]8;;https://example.test\x1b\\linked\x1b]8;;\x1b\\ plain",
            "\x1b[3;1H\x1b[2K\x1b[1K\x1b[2J\x1b[3J",
            "\x1b[2;3r\x1b[3;1Hscrolled\n\x1b[r\x1b[H",
            "\x1b[5brepeat me\x1b[2b",
            "\x1b[?2026hsynchronized 中 text\x1b[?2026l",
            "malformed \u{fffd} replacement",
        ];
        for cols in [1usize, 2, 3, 5, 8, 17, 80] {
            for graphemes in [false, true] {
                for chunk in [1usize, 3, 7, 64] {
                    assert_corpus_matches_scalar(cols, 4, 20, graphemes, &corpus, chunk);
                }
            }
        }
    }

    #[test]
    fn random_byte_streams_never_diverge_from_the_scalar_path() {
        // Arbitrary bytes: invalid UTF-8, truncated sequences, escapes that never
        // terminate, and long ordinary runs, in random chunk sizes.
        let mut rng = 0x5eed_1234_9abc_def0u64;
        for round in 0..24 {
            let mut bytes = Vec::new();
            for _ in 0..400 {
                rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let pick = (rng >> 33) as usize;
                bytes.push(match pick % 16 {
                    0..=5 => b"aZ 09!~"[pick % 7],
                    6 => 0x1b,
                    7 => b"[28;5;12HmDdJKP@Xrhl"[(pick >> 8) % 18],
                    8 => 0x0a,
                    9 => 0x0d,
                    10 => 0x09,
                    11 => "\u{4e2d}".as_bytes()[0],
                    12 => 0xc3,
                    13 => 0xff,
                    14 => "\u{301}".as_bytes()[pick % 2],
                    _ => "\u{200d}".as_bytes()[(pick >> 4) % 3],
                });
            }
            let text = String::from_utf8_lossy(&bytes).into_owned();
            let sanitized = text.as_bytes().iter().map(|&byte| byte as char).collect::<String>();
            let mut fast = Terminal::new(11, 3, 6).unwrap();
            let mut scalar = Terminal::new(11, 3, 6).unwrap();
            fast.enable_grapheme_support(round % 2 == 0);
            scalar.enable_grapheme_support(round % 2 == 0);
            let mut index = 0;
            while index < bytes.len() {
                rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1);
                let size = 1 + ((rng >> 40) as usize % 9);
                let end = (index + size).min(bytes.len());
                let part = &bytes[index..end];
                assert_eq!(feed_at(&mut fast, part, index as u64), feed_scalar(&mut scalar, part, index as u64));
                assert_eq!(state(&fast), state(&scalar), "round {round} offset {index}");
                index = end;
            }
            let _ = sanitized;
        }
    }

    #[test]
    fn run_writes_match_scalar_generations_and_history_bytes() {
        // History accounting and the generation counter must agree cell for cell, not
        // just in the visible text.
        let corpus = [
            "row one of plain text \r\n",
            "中中中中 with wide glyphs\r\n",
            "combining e\u{301}a\u{302} marks\r\n",
            "\x1b]8;;https://a.test\x1b\\linked row\x1b]8;;\x1b\\\r\n",
            "\x1b[38;2;1;2;3mtruecolor row\x1b[0m\r\n",
            "plain row that scrolls into history\r\n",
            "another scrolling row \r\n",
        ];
        for graphemes in [false, true] {
            let mut fast = Terminal::new(12, 2, 100).unwrap();
            let mut scalar = Terminal::new(12, 2, 100).unwrap();
            fast.enable_grapheme_support(graphemes);
            scalar.enable_grapheme_support(graphemes);
            for (index, text) in corpus.iter().enumerate() {
                let now = index as u64;
                for part in text.as_bytes().chunks(5) {
                    assert_eq!(feed_at(&mut fast, part, now), feed_scalar(&mut scalar, part, now));
                    assert_eq!(
                        fast.screen().history_bytes_for_test(),
                        scalar.screen().history_bytes_for_test(),
                        "history bytes differ at {text:?}"
                    );
                    for row in fast.screen().rows.iter().zip(scalar.screen().rows.iter()) {
                        assert_eq!(row.0.generation, row.1.generation, "generation differs at {text:?}");
                        assert_eq!(row.0.cells, row.1.cells, "cells differ at {text:?}");
                    }
                    for row in fast.screen().history.iter().zip(scalar.screen().history.iter()) {
                        assert_eq!(row.0.generation, row.1.generation, "history generation differs");
                        assert_eq!(row.0.cells, row.1.cells, "history cells differ");
                    }
                }
            }
            assert!(!fast.screen().history.is_empty(), "the corpus must scroll into history");
        }
    }

    #[test]
    fn resize_and_reflow_after_run_writes_match_the_scalar_path() {
        let corpus = [
            "abcdefghijklmnopqrstuvwxyz0123456789",
            "中文字元 and ascii mixed text that wraps",
            "👩🏽‍💻 emoji 🇯🇵 flags e\u{301} combining",
        ];
        for text in corpus {
            for (cols, rows) in [(7usize, 4usize), (4, 3), (13, 5), (2, 6)] {
                let mut fast = Terminal::new(19, 3, 50).unwrap();
                let mut scalar = Terminal::new(19, 3, 50).unwrap();
                fast.enable_grapheme_support(true);
                scalar.enable_grapheme_support(true);
                for part in text.as_bytes().chunks(6) {
                    assert_eq!(feed_at(&mut fast, part, 0), feed_scalar(&mut scalar, part, 0));
                }
                let mut actual = Vec::new();
                let mut expected = Vec::new();
                fast.resize(cols, rows, |event| actual.push(event)).unwrap();
                scalar.resize(cols, rows, |event| expected.push(event)).unwrap();
                assert_eq!(actual, expected, "{text:?} resized to {cols}x{rows}");
                assert_eq!(state(&fast), state(&scalar), "{text:?} resized to {cols}x{rows}");
                for part in text.as_bytes().chunks(9) {
                    assert_eq!(feed_at(&mut fast, part, 1), feed_scalar(&mut scalar, part, 1));
                    assert_eq!(state(&fast), state(&scalar));
                }
            }
        }
    }

    #[test]
    fn soft_reset_replaces_saved_cursor_position_and_attributes_with_defaults() {
        for alternate in [false, true] {
            let mut term = Terminal::new(8, 3, 10).unwrap();
            if alternate { feed(&mut term, b"\x1b[?1049h"); }
            feed(&mut term, b"kept\x1b[2;5H\x1b[31m\x1b(0\x1b7");
            feed(&mut term, b"\x1b[!p");
            assert_eq!(term.cursor(), Position { row: 1, col: 4 });
            feed(&mut term, b"\x1b8q");
            assert_eq!(term.cursor(), Position { row: 0, col: 1 });
            assert_eq!(term.screen().rows[0].text(), "qept    ");
            assert_eq!(term.screen().rows[0].cells[0].style(), Style::default());
        }
    }

    #[test]
    fn soft_reset_restores_a_hidden_cursor_without_erasing_or_moving_it() {
        for alternate in [false, true] {
            let mut term = Terminal::new(8, 3, 10).unwrap();
            if alternate { feed(&mut term, b"\x1b[?1049h"); }
            feed(&mut term, b"kept\x1b[2;3H\x1b[?25l");
            assert!(!term.modes.cursor_visible);
            feed(&mut term, b"\x1b[!p");
            assert!(term.modes.cursor_visible);
            assert_eq!(term.cursor(), Position { row: 1, col: 2 });
            assert_eq!(term.screen().rows[0].text(), "kept    ");
        }
    }

    #[test]
    fn soft_reset_restores_character_sets_and_cancels_a_single_shift() {
        for setup in ["\x1b(0", "\x1b)0\x0e", "\x1b*0\x1bN", "\x1b+0\x1bO"] {
            let mut term = Terminal::new(8, 2, 0).unwrap();
            feed(&mut term, setup.as_bytes());
            feed(&mut term, b"\x1b[!pqq");
            assert_eq!(term.screen().rows[0].text(), "qq      ", "setup {setup:?}");
            assert_eq!(term.charset, 0);
            assert_eq!(term.charsets, [false; 4]);
            assert_eq!(term.single_shift, None);
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
            assert_eq!(row.cells.iter().map(|c| (c.ch, c.width())).collect::<Vec<_>>(), expected);
        }
    }

    #[test]
    fn prefix_resets_match_full_resets_through_edits_backgrounds_history_and_resize() {
        fn assert_screen(a: &Screen, b: &Screen) {
            assert_eq!((a.cursor, a.saved_cursor, a.offset, a.selection),
                       (b.cursor, b.saved_cursor, b.offset, b.selection));
            assert_eq!((&a.region, &a.tabs, a.keyboard_flags, &a.keyboard_stack, a.cols),
                       (&b.region, &b.tabs, b.keyboard_flags, &b.keyboard_stack, b.cols));
            assert_eq!((a.rows.len(), a.history.len()), (b.rows.len(), b.history.len()));
            for (a, b) in a.rows.iter().chain(&a.history).zip(b.rows.iter().chain(&b.history)) {
                assert_eq!((a.id, &a.cells, a.wrapped, a.wrap_padding, a.generation),
                           (b.id, &b.cells, b.wrapped, b.wrap_padding, b.generation));
            }
            // Side records are shared by identity, so identical visible rows can hold a
            // different number of distinct records depending on how they were written
            // (one batched run versus one write per character). The charge must stay
            // deduplicated and comparable; the exact per-row formula is asserted by
            // `shared_presentation_rows_charge_one_record_not_one_per_cell` and friends.
            for screen in [a, b] {
                for row in screen.rows.iter().chain(&screen.history) {
                    let base = row.cells.capacity() * std::mem::size_of::<Cell>();
                    let naive: usize = row.cells.iter().map(Cell::side_bytes).sum();
                    assert!(row.bytes_for_test() >= base, "base storage is always charged");
                    assert!(
                        row.bytes_for_test() <= base + naive,
                        "a shared record is never charged twice"
                    );
                }
            }
            let (left, right) = (a.history_bytes_for_test(), b.history_bytes_for_test());
            assert!(
                left.abs_diff(right) <= left.max(right) / 2 + 4 * std::mem::size_of::<Cell>(),
                "history charges must stay comparable: {left} vs {right}"
            );
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
        // Controls clear the grapheme target before a following mark, and CSIs with
        // changing parameter counts pass through recycled records.
        let text = format!("{}\x1b[31mstyled\x1b[0m中\x1b[1;1Hwide overwrite\x1b(0qqq\x1b(Bascii{}\x1b[6n\x07",
                           "ordinary text 0123456789 ".repeat(600),
                           "a\n\u{301}b\x1b[1;2;3mc\x1b[m\x1b[38;5;1;4md\x0b\u{301}\x1b[2;3H");
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
            scalar.sync_deadline = None; scalar.sync.bytes = 0;
            let mut expected = Vec::new();
            let queued = scalar_queue(&scalar);
            scalar.sync.entries.clear(); scalar.sync.text.clear();
            for action in queued {
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
    fn entering_the_alternate_screen_restores_default_tab_stops() {
        // Stops cleared or added on the alternate screen do not survive its next clear.
        let defaults = Terminal::new(20, 2, 0).unwrap().alternate.tabs.clone();
        for edit in ["\x1b[3g", "\x1b[1;3H\x1bH", "\x1b[1;9H\x1b[g"] {
            let mut term = Terminal::new(20, 2, 0).unwrap();
            feed(&mut term, format!("\x1b[?1049h{edit}\x1b[?1049l").as_bytes());
            assert_ne!(term.alternate.tabs, defaults, "{edit:?} changed a stop");
            feed(&mut term, b"\x1b[?1049h");
            assert_eq!(term.alternate.tabs, defaults, "{edit:?}");
        }
    }
    #[test]
    fn erasing_rows_that_are_already_blank_keeps_their_generation() {
        // ED and EL over rows that would come out identical leave them untouched, so a
        // snapshot does not resend them; rows with content or wrap state still change.
        // Each case names the rows it erases whole; a partial erase still edits cells.
        let cases: [(&str, &[usize]); 4] = [
            ("\x1b[2J", &[0, 1, 2]),
            ("\x1b[1;1H\x1b[J", &[0, 1, 2]),
            ("\x1b[3;1H\x1b[1J", &[0, 1]),
            ("\x1b[2;1H\x1b[2K", &[1]),
        ];
        for (erase, whole) in cases {
            let mut term = Terminal::new(6, 3, 0).unwrap();
            // Row 0 wraps into row 1 and row 2 holds text, so the first erase changes them.
            feed(&mut term, b"abcdefgh\x1b[3;1Hz");
            let written: Vec<u64> = term.main.rows.iter().map(|row| row.generation).collect();
            feed(&mut term, erase.as_bytes());
            let erased: Vec<u64> = term.main.rows.iter().map(|row| row.generation).collect();
            feed(&mut term, erase.as_bytes());
            let again: Vec<u64> = term.main.rows.iter().map(|row| row.generation).collect();
            for &row in whole {
                assert_ne!(erased[row], written[row], "{erase:?} row {row} had content");
                assert_eq!(again[row], erased[row], "{erase:?} row {row} was already blank");
            }
        }
        // A row of blanks that still carries wrap state is cleared of it. Input cannot
        // produce one today (full-width erases clear the flags), so set it directly.
        let mut term = Terminal::new(4, 2, 0).unwrap();
        term.main.rows[0].wrapped = true;
        let generation = term.main.rows[0].generation;
        feed(&mut term, b"\x1b[2K");
        assert!(!term.main.rows[0].wrapped);
        assert_ne!(term.main.rows[0].generation, generation);
    }
    #[test]
    fn full_erases_after_a_coloured_partial_erase_restore_default_blanks() {
        // The skip for rows already certified blank must not hide a partial erase in
        // another colour, through ED/EL or the alternate screen's clear.
        let mut term = Terminal::new(12, 2, 0).unwrap();
        feed(&mut term, b"\x1b[41m\x1b[1;5H\x1b[K\x1b[0m\x1b[2K");
        let fresh = Terminal::new(12, 2, 0).unwrap();
        assert_eq!(term.main.rows[0].cells, fresh.main.rows[0].cells);
        let mut term = Terminal::new(12, 2, 0).unwrap();
        feed(&mut term, b"\x1b[41m\x1b[1;5H\x1b[K\x1b[0m\x1b[?1049h\x1b[?1049l\x1b[2J");
        assert_eq!(term.main.rows[0].cells, fresh.main.rows[0].cells);
    }
    #[test]
    fn word_prefixes_match_their_one_at_a_time_forms() {
        // Every length up to three words, with the stopping element at every position.
        for length in 0..=24usize {
            for stop in 0..=length {
                let mut bytes = vec![b'a'; length];
                if stop < length { bytes[stop] = 0xe4; }
                assert_eq!(ascii_prefix(&bytes), bytes.iter().take_while(|b| b.is_ascii()).count());
                let mut wide = Terminal::new(2, 1, 0).unwrap();
                feed(&mut wide, "中".as_bytes());
                let mut cells = vec![Cell::default(); length];
                if stop < length { cells[stop] = wide.main.rows[0].cells[(stop % 2).min(1)].clone(); }
                assert_eq!(single_width_prefix(&cells), cells.iter().take_while(|c| c.width() == 1).count(),
                           "length {length} stop {stop}");
            }
        }
    }
    #[test]
    fn ascii_runs_scan_cells_when_the_blank_certificate_is_stale() {
        // A cell change that bypasses the row's write tracking leaves its blank
        // certificate stale. ASCII written over either half of a wide glyph must
        // still repair the other half.
        for (column, text) in [(5, "a"), (6, "a"), (4, "ab"), (6, "abc")] {
            let edit = format!("\x1b[1;{column}H{text}");
            let mut reference = Terminal::new(12, 2, 0).unwrap();
            feed(&mut reference, format!("\x1b[1;5H中{edit}").as_bytes());
            let mut wide = Terminal::new(12, 2, 0).unwrap();
            feed(&mut wide, "\x1b[1;5H中".as_bytes());
            let mut term = Terminal::new(12, 2, 0).unwrap();
            let row = &mut term.main.rows[0];
            row.cells.clone_from(&wide.main.rows[0].cells);
            row.generation = row.generation.wrapping_add(1);
            feed(&mut term, edit.as_bytes());
            assert_eq!(term.main.rows[0].cells, reference.main.rows[0].cells, "{edit:?}");
        }
    }
    #[test]
    fn ascii_runs_overwrite_heap_rows_and_blanks_without_losing_records() {
        // Rows holding links, combining marks and RGB blanks take the destructor path;
        // heap-free rows take plain stores. Both must agree with the scalar path.
        let corpus = [
            "\x1b]8;;https://example.test\x1b\\linked\x1b]8;;\x1b\\\x1b[1;1Hplain over link",
            "e\u{301}e\u{301}\x1b[1;1Hascii over marks\r\n",
            "\x1b[48;2;1;2;3m\x1b[2Kblank rgb\x1b[0m\r\nnext\r\n\x1b[3;1Hover rgb\n\n\n",
            "ordinary text written into recycled rows 0123456789\r\n",
        ];
        for chunk in [1usize, 5, 64] {
            assert_corpus_matches_scalar(9, 3, 0, false, &corpus, chunk);
            assert_corpus_matches_scalar(9, 3, 4, true, &corpus, chunk);
        }
    }
    #[test]
    fn frames_closed_within_a_chunk_match_queued_frames() {
        // Whole chunks apply a closed frame directly; one byte at a time every frame is
        // queued and replayed. Events and the whole state must agree after each chunk.
        let big = "x".repeat(MAX_SYNC_MEMORY / std::mem::size_of::<Action>() + 3);
        let cases = [
            "a\x1b[?2026hb\x1b[6nc\x1b[?2026$pd\x1b[?2026le\x1b[?2026$p".to_string(),
            "\x1b[?2026h\x1b]0;t\x1b[?2026lafter\x1b[?2026l".to_string(),
            "\x1b[?2026h\x1bP1$r\x1b[?2026lafter".to_string(),
            "\x1b[?2026hx\u{9b}?2026ly\x1b[6n".to_string(),
            "\x1b[?2026hx\x1b[?2026:1ly\x1b[?2026lz".to_string(),
            "\x1b[?2026hx\x1b[?2026;25ly\x1b[6n\x1b[?2026lz".to_string(),
            "\x1b[?2026hx\x1b[?2026hy\x1b[?2026l\x1b[?2026hz\x1b[6n".to_string(),
            "e\x1b[?2026h\u{301}\x1b[?2026l\u{301}\x1b[?2026;25hq\x1b[?2026l".to_string(),
            format!("\x1b[?2026h\x1b[31m{big}\x1b[6n\x1b[?2026h{big}\x1b[?2026lend"),
            "\x1b[?2026hopen frame \x1b[6n".to_string(),
        ];
        for case in &cases {
            for split in [None, Some(case.len() / 2)] {
                let mut whole = Terminal::new(9, 3, 4).unwrap();
                let mut bytes = Terminal::new(9, 3, 4).unwrap();
                for term in [&mut whole, &mut bytes] { term.enable_grapheme_support(true); }
                let parts: Vec<&[u8]> = match split {
                    Some(at) => vec![&case.as_bytes()[..at], &case.as_bytes()[at..]],
                    None => vec![case.as_bytes()],
                };
                for part in parts {
                    let expected: Vec<Event> = part.chunks(1).flat_map(|byte| feed_at(&mut bytes, byte, 0)).collect();
                    assert_eq!(feed_at(&mut whole, part, 0), expected, "{case:?}");
                    // Only the live parser state matters; its UTF-8 scratch bytes
                    // depend on how the input was chunked.
                    whole.parser.clear_scratch_for_test();
                    bytes.parser.clear_scratch_for_test();
                    // The revision counts `feed` calls, not content.
                    whole.revision = bytes.revision;
                    assert_eq!(state(&whole), state(&bytes), "{case:?} split {split:?}");
                }
            }
        }
    }
    #[test]
    fn sync_end_counts_match_a_byte_search() {
        // Ends among near misses: other finals, introducers, a cut-off end, `?` at the
        // very start, repeated `?`, with every split of a pseudo-random concatenation.
        let end = b"\x1b[?2026l";
        let fragments: [&[u8]; 9] = [end, b"?", b"\x1b[?2026h", b"x[?2026l", b"\x1b]?2026l",
                                     b"\x1b[??2026l", b"plain text ", b"\x1b[?2026", b"\x1b"];
        let mut seed = 0x9e37_79b9u32;
        for _ in 0..2000 {
            let mut bytes = Vec::new();
            for _ in 0..(seed % 9) {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                bytes.extend_from_slice(fragments[(seed >> 24) as usize % fragments.len()]);
            }
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let naive = bytes.windows(end.len()).filter(|window| window == end).count();
            assert_eq!(count_sync_ends(&bytes), naive, "{bytes:?}");
            for start in 0..bytes.len() {
                assert_eq!(find_byte(&bytes[start..], b'?'), bytes[start..].iter().position(|&b| b == b'?'));
            }
        }
    }
    #[test]
    fn deferred_text_overflows_at_the_scalar_queue_bound() {
        // A per-character queue flushes on the character that reaches the memory bound.
        // Runs that end just short of, on and just past that character must agree, as
        // must runs behind other queued actions and runs of multi-byte characters.
        let charge = std::mem::size_of::<Action>();
        let room = MAX_SYNC_MEMORY.div_ceil(charge);
        for lead in ["", "\x1b[31m", "\x1b[1;2H\x1b]0;title\x07"] {
            for unit in ["a", "中", "é"] {
                for count in room - 2..=room + 1 {
                    let body = unit.repeat(count);
                    let text = format!("\x1b[?2026h{lead}{body}\x1b[6nafter\x1b[?2026lend");
                    let split = text.find("\x1b[6n").unwrap();
                    for chunk in [split + 1, 4093] {
                        assert_corpus_matches_scalar(9, 3, 4, false, &[&text], chunk);
                    }
                }
            }
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
        assert!(term.screen().rows[0].cells[3].combining().contains(&'\u{fe0f}'));
        // With DECAWM on (the default) the cluster still wraps to the next row.
        let mut term = Terminal::new(4, 2, 10).unwrap();
        term.enable_grapheme_support(true);
        feed(&mut term, "abc\u{2764}\u{fe0f}".as_bytes());
        assert_eq!(term.cursor().row, 1, "wrap allowed with DECAWM on");
    }
    #[test]
    fn width_changing_graphemes_keep_a_bounded_modified_prefix() {
        let mut term = Terminal::new(12, 2, 10).unwrap();
        term.enable_grapheme_support(true);
        feed(&mut term, "abc\u{2764}".as_bytes());
        assert_eq!(term.screen().rows[0].modified_end_for_test(), 4);
        feed(&mut term, "\u{fe0f}".as_bytes());
        assert_eq!(term.screen().rows[0].cells[3].width(), 2);
        assert_eq!(term.screen().rows[0].modified_end_for_test(), 5);
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
            term.screen().rows[0].cells[0].combining_len(),
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
            .all(|c| c.style().bg == Color::Indexed(1))));
        // A different BCE colour must refill, not reuse the red blank marker.
        feed(&mut term, b"\x1b[44m\x1b[2J");
        assert!(
            term.screen().rows.iter().all(|row| row
                .cells
                .iter()
                .all(|c| c.style().bg == Color::Indexed(4))),
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
        assert_eq!(term.screen().rows[0].cells[0].width(), 2);
        assert_eq!(term.screen().rows[0].cells[1].width(), 0);
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
    fn repeated_runs_reuse_the_prepared_style_template() {
        let mut term = Terminal::new(20, 4, 10).unwrap();
        term.enable_grapheme_support(true);
        feed(&mut term, b"plain text\r\n");
        let plain = term.template_builds_for_test();
        assert_eq!(plain, 1, "the first write prepares one template");
        for _ in 0..8 {
            feed(&mut term, b"plain text\r\n");
        }
        assert_eq!(
            term.template_builds_for_test(),
            plain,
            "an unchanged style and hyperlink must reuse the template"
        );
        feed(&mut term, b"\x1b[38;2;80;180;240m");
        for _ in 0..8 {
            feed(&mut term, b"truecolor text\r\n");
        }
        let rgb = term.template_builds_for_test();
        assert_eq!(rgb, plain + 1, "one rebuild for the RGB style, none per run");
        feed(&mut term, b"\x1b]8;;https://example.test\x1b\\");
        for _ in 0..8 {
            feed(&mut term, b"linked text\r\n");
        }
        assert_eq!(
            term.template_builds_for_test(),
            rgb + 1,
            "one rebuild for the hyperlink, none per run"
        );
        // A combining mark shares the cached record without rebuilding it.
        feed(&mut term, "e\u{301}".as_bytes());
        feed(&mut term, b"more");
        assert_eq!(term.template_builds_for_test(), rgb + 1);
    }

    #[test]
    fn alternating_styles_reuse_the_bounded_slot_set() {
        let mut term = Terminal::new(12, 3, 10).unwrap();
        term.enable_grapheme_support(true);
        // The shape that used to rebuild (and reallocate) once per line: a truecolor
        // accent followed by the reset style, over and over.
        for _ in 0..12 {
            feed(&mut term, b"\x1b[38;2;80;180;240maccent\x1b[0m plain\r\n");
        }
        assert_eq!(
            term.template_builds_for_test(),
            2,
            "two alternating styles keep both templates without a per-line rebuild"
        );
        // The slot set is bounded: more distinct styles than slots still builds once each
        // and never grows the retained set.
        for index in 0..8 {
            let escape = format!("\x1b[38;2;{index};0;0mX");
            feed(&mut term, escape.as_bytes());
        }
        assert_eq!(term.template_builds_for_test(), 2 + 8, "each new style builds once");
        // The most recently used style is still resident, so it costs nothing again.
        let settled = term.template_builds_for_test();
        feed(&mut term, b"\x1b[38;2;7;0;0mY");
        assert_eq!(
            term.template_builds_for_test(),
            settled,
            "the newest style stays warm"
        );
        // A style pushed out of the bounded set rebuilds exactly once when it returns.
        feed(&mut term, b"\x1b[38;2;80;180;240maccent");
        assert_eq!(term.template_builds_for_test(), settled + 1);
        assert_eq!(
            term.screen().rows.back().unwrap().cells[0].style().fg,
            Color::rgb(80, 180, 240)
        );
    }

    #[test]
    fn every_style_change_rebuilds_the_template_and_reaches_the_cells() {
        let cases: &[(&str, Style)] = &[
            ("", Style::default()),
            ("\x1b[1m", Style { attrs: cell::BOLD, ..Style::default() }),
            ("\x1b[2m", Style { attrs: cell::FAINT, ..Style::default() }),
            ("\x1b[3m", Style { attrs: cell::ITALIC, ..Style::default() }),
            ("\x1b[5m", Style { attrs: cell::BLINK, ..Style::default() }),
            ("\x1b[7m", Style { attrs: cell::INVERSE, ..Style::default() }),
            ("\x1b[8m", Style { attrs: cell::INVISIBLE, ..Style::default() }),
            ("\x1b[9m", Style { attrs: cell::STRIKE, ..Style::default() }),
            ("\x1b[4m", Style { underline: 1, ..Style::default() }),
            ("\x1b[4:3m", Style { underline: 3, ..Style::default() }),
            ("\x1b[21m", Style { underline: 2, ..Style::default() }),
            ("\x1b[31m", Style { fg: Color::Indexed(1), ..Style::default() }),
            ("\x1b[91m", Style { fg: Color::Indexed(9), ..Style::default() }),
            ("\x1b[38;5;200m", Style { fg: Color::Indexed(200), ..Style::default() }),
            ("\x1b[38;2;1;2;3m", Style { fg: Color::rgb(1, 2, 3), ..Style::default() }),
            ("\x1b[41m", Style { bg: Color::Indexed(1), ..Style::default() }),
            ("\x1b[48;5;17m", Style { bg: Color::Indexed(17), ..Style::default() }),
            ("\x1b[48;2;4;5;6m", Style { bg: Color::rgb(4, 5, 6), ..Style::default() }),
            (
                "\x1b[58;2;7;8;9;4:4m",
                Style {
                    underline: 4,
                    underline_color: Some(Color::rgb(7, 8, 9)),
                    ..Style::default()
                },
            ),
            (
                "\x1b[58;5;42m",
                Style { underline_color: Some(Color::Indexed(42)), ..Style::default() },
            ),
            ("\x1b[38;2;1;2;3m\x1b[39m", Style::default()),
            ("\x1b[48;2;1;2;3m\x1b[49m", Style::default()),
            ("\x1b[58;2;7;8;9m\x1b[59m", Style::default()),
            ("\x1b[1;3;31;4:2m\x1b[0m", Style::default()),
            (
                "\x1b[1;3;31;4:2;58;2;9;9;9m",
                Style {
                    attrs: cell::BOLD | cell::ITALIC,
                    fg: Color::Indexed(1),
                    underline: 2,
                    underline_color: Some(Color::rgb(9, 9, 9)),
                    ..Style::default()
                },
            ),
        ];
        for (escape, expected) in cases {
            let mut term = Terminal::new(8, 2, 4).unwrap();
            feed(&mut term, escape.as_bytes());
            let prepared = term.template_builds_for_test();
            feed(&mut term, b"X");
            assert_eq!(
                term.screen().rows[0].cells[0].style(),
                *expected,
                "{escape:?} must reach the cell"
            );
            assert_eq!(
                term.template_builds_for_test(),
                prepared + 1,
                "{escape:?} must rebuild exactly once"
            );
            // Repeating the write must not rebuild again.
            feed(&mut term, b"Y");
            assert_eq!(term.template_builds_for_test(), prepared + 1, "{escape:?} reused");
        }
    }

    #[test]
    fn hyperlink_changes_update_cells_without_stale_links() {
        let mut term = Terminal::new(8, 2, 4).unwrap();
        feed(&mut term, b"\x1b]8;;https://a.test\x1b\\");
        feed(&mut term, b"A");
        let opened = term.template_builds_for_test();
        feed(&mut term, b"\x1b]8;;https://b.test\x1b\\");
        feed(&mut term, b"B");
        feed(&mut term, b"\x1b]8;;\x1b\\");
        feed(&mut term, b"C");
        feed(&mut term, b"D");
        let row = &term.screen().rows[0];
        assert_eq!(row.cells[0].link_uri(), Some("https://a.test"));
        assert_eq!(row.cells[1].link_uri(), Some("https://b.test"));
        assert_eq!(row.cells[2].link_uri(), None, "closing OSC 8 must not keep the link");
        assert_eq!(row.cells[3].link_uri(), None);
        assert_eq!(
            term.template_builds_for_test(),
            opened + 2,
            "one rebuild per hyperlink change, none for repeated writes"
        );
        // A different hyperlink Arc always rebuilds, even with an equal target text.
        feed(&mut term, b"\x1b]8;;https://b.test\x1b\\");
        feed(&mut term, b"E");
        assert_eq!(term.screen().rows[0].cells[4].link_uri(), Some("https://b.test"));
    }

    #[test]
    fn soft_reset_and_cursor_restore_reach_the_next_run() {
        // Styled text, then a style change that is not an SGR, then more text: the
        // second run must take the new presentation, not the cached template.
        let plain = {
            let mut term = Terminal::new(10, 2, 0).unwrap();
            feed(&mut term, b"ab");
            term.screen().rows[0].cells[1].clone()
        };
        for change in [&b"\x1b[!p"[..], b"\x1b8", b"\x1bc"] {
            let mut term = Terminal::new(10, 2, 0).unwrap();
            feed(&mut term, b"\x1b7\x1b[31;1mxa");
            feed(&mut term, change);
            feed(&mut term, b"\rab");
            let cell = &term.screen().rows[0].cells[1];
            assert_eq!(format!("{cell:?}"), format!("{plain:?}"), "{change:?}");
        }
    }

    #[test]
    fn alternate_screen_switch_and_reset_keep_the_template_honest() {
        let mut term = Terminal::new(8, 2, 4).unwrap();
        term.preserve_erased_screen = false;
        feed(&mut term, b"\x1b[31mM");
        feed(&mut term, b"\x1b[?1049h\x1b[32mA");
        assert_eq!(term.screen().rows[0].cells[0].style().fg, Color::Indexed(2));
        feed(&mut term, b"\x1b[?1049l");
        let main = &term.screen().rows[0];
        assert_eq!(main.cells[0].ch, 'M');
        assert_eq!(main.cells[0].style().fg, Color::Indexed(1), "main keeps its own style");
        feed(&mut term, b"\x1b[1;2HN");
        assert_eq!(
            term.screen().rows[0].cells[1].style().fg,
            Color::Indexed(1),
            "the red style survives an alternate-screen round trip"
        );
        // RIS restores defaults, so later writes must not reuse the old presentation.
        feed(&mut term, b"\x1bc");
        feed(&mut term, b"R");
        assert_eq!(term.screen().rows[0].cells[0].style(), Style::default());
    }

    #[test]
    fn cached_template_never_absorbs_combining_marks() {
        let mut term = Terminal::new(8, 2, 4).unwrap();
        feed(&mut term, b"\x1b[38;2;1;2;3m");
        feed(&mut term, "e\u{301}".as_bytes());
        let prepared = term.template_builds_for_test();
        feed(&mut term, b"xyz");
        let row = &term.screen().rows[0];
        assert_eq!(row.cells[0].combining().len(), 1, "the mark stays on its own cell");
        assert!(row.cells[1].combining().is_empty(), "the shared record stays combining-free");
        assert!(row.cells[2].combining().is_empty());
        assert_eq!(row.cells[1].style().fg, Color::rgb(1, 2, 3), "same prepared presentation");
        assert_eq!(term.template_builds_for_test(), prepared, "no rebuild after a mark");
    }

    #[test]
    fn stateful_grapheme_sequences_match_scalar_clustering_through_runs() {
        // Clusters whose membership depends on more than the last written character:
        // ZWJ pictographs, regional indicator runs of every length, keycaps, skin tone
        // modifiers, tag sequences, and the same sequences mixed with plain text.
        let corpus = [
            "\u{1f469}\u{1f3fd}\u{200d}\u{1f4bb}",
            "\u{1f469}\u{200d}\u{1f4bb}\u{1f468}\u{200d}\u{1f4bb}",
            "\u{1f3f3}\u{fe0f}\u{200d}\u{1f308}",
            "\u{2764}\u{fe0f}\u{200d}\u{1f525}",
            "\u{1f1ef}\u{1f1f5}",
            "\u{1f1ef}\u{1f1f5}\u{1f1fa}\u{1f1f8}",
            "\u{1f1fa}\u{1f1f8}\u{1f1ec}\u{1f1e7}\u{1f1eb}\u{1f1f7}",
            "\u{1f1ef}",
            "\u{1f1ef}\u{1f1f5}\u{1f1fa}",
            "a\u{1f1ef}\u{1f1f5}b",
            "中\u{1f469}\u{200d}\u{1f4bb}中",
            "1\u{fe0f}\u{20e3}2\u{fe0f}\u{20e3}",
            "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}",
            "e\u{301}\u{302}x \u{915}\u{94d}\u{937}",
            "\u{1f1ef}\u{1f1f5}\u{1f1fa}\u{1f1f8}\u{1f1ec}\u{1f1e7}\u{1f1eb}\u{1f1f7}",
        ];
        for cols in [1usize, 2, 3, 4, 5, 9, 20] {
            for graphemes in [false, true] {
                for chunk in [1usize, 2, 3, 5, 64] {
                    assert_corpus_matches_scalar(cols, 3, 10, graphemes, &corpus, chunk);
                }
            }
        }
    }

    #[test]
    fn cluster_shaped_runs_match_scalar_prints_in_full_state() {
        // Every cluster shape a batched run now writes itself: CJK, a lone pictograph, a
        // skin tone modifier, the ZWJ family, regional indicator flags, conjoining and
        // precomposed Hangul, combining marks, and plain text between them.
        let corpus = [
            "中文字元漢字",
            "😀 😀 😀",
            "😀🏽✌🏽👍🏿",
            "👩🏽\u{200d}💻👨\u{200d}👩\u{200d}👧\u{200d}👦🏳️\u{200d}🌈",
            "🇯🇵🇺🇸🇬🇧🇫🇷🇯",
            "\u{1100}\u{1161}\u{11a8} 한 국 \u{ac00}\u{11a8}",
            "e\u{301}\u{302}\u{303} a\u{308} 중\u{301}",
            "中👩\u{200d}💻🇯🇵한e\u{301}plain ascii tail",
            "\x1b[1;1H中\u{301}\x1b[1;2H👩\u{200d}💻wide repair",
        ];
        for cols in [1usize, 2, 3, 5, 9, 20] {
            for graphemes in [false, true] {
                for chunk in [1usize, 2, 3, 6, 64] {
                    assert_corpus_matches_scalar(cols, 3, 12, graphemes, &corpus, chunk);
                }
            }
        }
        // The run must actually take these lead characters instead of handing every one
        // of them to the scalar printer.
        fn run(text: &str) -> usize {
            let mut term = Terminal::new(20, 2, 0).unwrap();
            term.enable_grapheme_support(true);
            let template = term.style_template();
            term.write_run(text, false, &template).bytes
        }
        assert_eq!(run("中文字"), 9, "CJK is written as one run");
        assert_eq!(run("😀😀"), 8, "lone pictographs are written as a run");
        assert_eq!(run("🇯🇵"), 4, "a flag breaks after its first indicator");
        assert_eq!(run("\u{1100}\u{1161}"), 3, "jamo break before composing");
    }

    #[test]
    fn cluster_analysis_cache_hits_breaks_and_bounded_eviction() {
        let mut term = Terminal::new(20, 3, 10).unwrap();
        term.enable_grapheme_support(true);
        feed(&mut term, "👩🏽\u{200d}💻".as_bytes());
        assert_eq!(term.cluster_analysis("👩🏽"), Some((true, 2)));
        assert_eq!(term.cluster_analysis("👩🏽\u{200d}💻"), Some((true, 2)));
        // Every continuation of the second family reads the entries written above.
        feed(&mut term, "👩🏽\u{200d}💻".as_bytes());
        assert_eq!(term.screen().rows[0].cells[0].text(), "👩🏽\u{200d}💻");
        assert_eq!(term.screen().rows[0].cells[2].text(), "👩🏽\u{200d}💻");

        let mut unknown = Terminal::new(20, 3, 10).unwrap();
        unknown.enable_grapheme_support(true);
        feed(&mut unknown, "中\u{915}".as_bytes());
        assert_eq!(unknown.cluster_analysis("中\u{915}").map(|entry| entry.0), Some(false));
        feed(&mut unknown, "中\u{915}".as_bytes());
        assert_eq!(unknown.screen().rows[0].cells[3].ch, '中');
        assert_eq!(unknown.screen().rows[0].cells[5].ch, '\u{915}');

        for index in 0..CLUSTER_SLOTS * 2 {
            term.remember_cluster(&format!("cluster{index}"), true, 1);
        }
        assert_eq!(term.cluster_cache.iter().flatten().count(), CLUSTER_SLOTS);
        assert_eq!(term.cluster_analysis("cluster0"), None);
        assert_eq!(term.cluster_analysis("cluster19"), Some((true, 1)));
        let slot = term.cluster_slot;
        term.remember_cluster(&"x".repeat(CLUSTER_KEY_BYTES + 1), true, 1);
        assert_eq!(term.cluster_slot, slot, "an oversized key is not retained");

        let corpus = [
            "👩🏽\u{200d}💻👩🏽\u{200d}💻 🇯🇵🇺🇸🇬🇧🇫🇷",
            "👨\u{200d}👩\u{200d}👧\u{200d}👦👨\u{200d}👩\u{200d}👧\u{200d}👦",
            "中\u{915}中\u{915} e\u{301}\u{302}e\u{301}\u{302}",
            "🏳️\u{200d}🌈🏳️\u{200d}🌈 ❤\u{fe0f}❤\u{fe0f}",
        ];
        for cols in [2usize, 9, 20] {
            for chunk in [1usize, 3, 64] {
                assert_corpus_matches_scalar(cols, 3, 12, true, &corpus, chunk);
            }
        }
    }

    #[test]
    fn classified_pair_runs_match_the_scalar_printer() {
        // The run writer classifies each character once and carries that class into the
        // next pair decision. The corpus covers ordinary text, the unmodelled scripts
        // that must defer (`Unknown`), regional indicator runs of both parities, ZWJ
        // sequences and the same shapes mixed together.
        let corpus = [
            "ordinary ascii text 0123456789",
            "中文字元漢字 한국어",
            "\u{915}\u{94d}\u{937} \u{928}\u{92e}\u{938}\u{94d}\u{924}\u{947}",
            "\u{627}\u{644}\u{639}\u{631}\u{628}\u{64a}\u{629} \u{5d0}\u{5d1}\u{5d2}",
            "\u{e01}\u{e33}\u{e49}\u{e32}\u{e19} \u{1780}\u{17d2}\u{1799}\u{17b6}",
            "🇯🇵 🇺🇸🇬🇧\u{1f1eb}\u{1f1f7}\u{1f1ef} 🇩",
            "🇯🇵🇺🇸🇬🇧🇫🇷🇯🇩🇪🇮🇹",
            "👩🏽\u{200d}💻 👨\u{200d}👩\u{200d}👧 🏳️\u{200d}🌈 ❤\u{fe0f}\u{200d}🔥",
            "a🇯🇵b👩\u{200d}💻c\u{915}\u{94d}\u{937}d",
            "e\u{301}\u{302} 중\u{301} 1\u{fe0f}\u{20e3}",
            "\u{600}abc\u{604}xyz",
            "\u{1100}\u{1161}\u{11a8}\u{ac00}\u{11a8}",
            "mix 中👩\u{200d}💻🇯🇵한\u{301} tail",
        ];
        for cols in [1usize, 2, 3, 5, 9, 20] {
            for graphemes in [false, true] {
                for chunk in [1usize, 2, 3, 7, 64] {
                    assert_corpus_matches_scalar(cols, 3, 12, graphemes, &corpus, chunk);
                }
            }
        }
    }

    #[test]
    fn long_ascii_after_a_non_ascii_character_returns_to_the_packed_path() {
        fn run(text: &str) -> usize {
            let mut term = Terminal::new(80, 2, 0).unwrap();
            term.enable_grapheme_support(true);
            let template = term.style_template();
            term.write_run(text, false, &template).bytes
        }
        let long = "a".repeat(ASCII_HANDOFF);
        let short = "a".repeat(ASCII_HANDOFF - 1);
        assert_eq!(run(&format!("中{long}")), 3, "the cell path stops before a long ASCII stretch");
        assert_eq!(run(&format!("中{short}")), 3 + short.len(), "a short stretch stays");
        assert_eq!(run(&format!("中{short}é{long}")), 3 + short.len() + 2);
        // The packed path then writes the stretch whole, ending where the scalar path does.
        for text in [format!("中{long}中{short}"), format!("é{long}{long}")] {
            let mut fast = Terminal::new(40, 3, 0).unwrap();
            let mut scalar = Terminal::new(40, 3, 0).unwrap();
            for term in [&mut fast, &mut scalar] { term.enable_grapheme_support(true); }
            feed(&mut fast, text.as_bytes());
            feed_scalar(&mut scalar, text.as_bytes(), 0);
            assert_eq!(state(&fast), state(&scalar), "{text:?}");
        }
    }

    #[test]
    fn runs_classify_each_character_once() {
        // The carried class is the whole point of this path: a run must never ask for a
        // character's class twice (once as `next`, once as the tail of the next pair).
        fn run(text: &str) -> (usize, usize) {
            let mut term = Terminal::new(20, 2, 0).unwrap();
            term.enable_grapheme_support(true);
            let template = term.style_template();
            grapheme::reset_classifications_for_test();
            let written = term.write_run(text, false, &template);
            (written.bytes, grapheme::classifications_for_test())
        }
        // Simple characters (CJK, kana, Hangul syllables, Latin) need no lookup at all.
        assert_eq!(run("中文字"), (9, 0));
        assert_eq!(run("한국어"), (9, 0));
        assert_eq!(run("中a中é"), (9, 0));
        // Any other character is classified once, as `next` and then as the tail.
        assert_eq!(run("😀😀😀"), (12, 3), "one class per pictograph written");
        assert_eq!(run("中😀中"), (10, 3), "a simple neighbour is classified once when needed");
        // The packed ASCII prefix is batched before any pair decision is taken.
        assert_eq!(run("e\u{301}"), (1, 0));
        // Pure ASCII pairs are decided by the character test alone.
        assert_eq!(run("abc"), (3, 0));
        // The pair itself, plus the exact look-behind that counts the regional run.
        assert_eq!(run("🇯🇵"), (4, 3));
        // Unmodelled scripts still classify each side once before deferring.
        let (bytes, classes) = run("\u{915}\u{94d}\u{937}");
        assert_eq!(bytes, 3, "only the base character is written by the run");
        assert!(classes <= 3, "{classes} classifications for two deferred pairs");
    }

    #[test]
    fn complete_feeds_reuse_the_boundary_verdict_across_scalar_fallback() {
        fn classifications(text: &str, chunk: usize) -> usize {
            let mut term = Terminal::new(20, 2, 0).unwrap();
            term.enable_grapheme_support(true);
            grapheme::reset_classifications_for_test();
            for bytes in text.as_bytes().chunks(chunk) { feed(&mut term, bytes); }
            grapheme::classifications_for_test()
        }
        for chunk in [1, 2, 3, 7, 64] {
            assert_eq!(classifications("e\u{301}", chunk), 2, "one pair decision, chunk {chunk}");
            assert_eq!(
                classifications("👩🏽\u{200d}💻", chunk),
                6,
                "three pair decisions, chunk {chunk}",
            );
        }
    }

    #[test]
    fn repeated_combining_appends_keep_content_presentation_and_link() {
        let mut term = Terminal::new(10, 2, 8).unwrap();
        term.enable_grapheme_support(true);
        // A linked truecolor cell: its record carries presentation, link and marks.
        feed(&mut term, b"\x1b[38;2;7;8;9m\x1b]8;;https://example.test\x1b\\e\x1b]8;;\x1b\\");
        let style = term.screen().rows[0].cells[0].style();
        assert_eq!(style.fg, Color::rgb(7, 8, 9));
        for step in 1..=cell::MAX_COMBINING {
            feed(&mut term, "\u{301}".as_bytes());
            let cell = &term.screen().rows[0].cells[0];
            assert_eq!(cell.ch, 'e');
            assert_eq!(cell.width(), 1);
            assert_eq!(cell.combining_len(), step, "append {step}");
            assert!(cell.combining().iter().all(|&mark| mark == '\u{301}'));
            assert_eq!(cell.style(), style, "presentation survives append {step}");
            assert_eq!(cell.link_uri(), Some("https://example.test"), "link survives append {step}");
            assert_row_charge_matches_records(&term, 0);
        }
        assert_charges_exact(&term, "combining appends");
        // The per-cell bound is exact: one more mark is dropped, not appended.
        feed(&mut term, "\u{301}".as_bytes());
        assert_eq!(term.screen().rows[0].cells[0].combining_len(), cell::MAX_COMBINING);
        // The marks travel with the row when it scrolls, and history charges them once.
        feed(&mut term, b"\r\nscrolled\r\n");
        assert_charges_exact(&term, "after the marked row scrolls");
        assert!(
            term.screen().history.iter().any(|row| row.cells[0].combining_len() == cell::MAX_COMBINING),
            "the marks stay with the row that scrolled away"
        );
        let summed: usize = term.screen().history.iter().map(|row| row.bytes_for_test()).sum();
        assert_eq!(term.screen().history_bytes_for_test(), summed, "history keeps the exact charge");
    }

    /// A row's charge must be its cell storage plus each distinct side record once.
    fn assert_row_charge_matches_records(term: &Terminal, row: usize) {
        let row = &term.screen().rows[row];
        let base = row.cells.capacity() * std::mem::size_of::<Cell>();
        let mut distinct: Vec<&Cell> = Vec::new();
        for cell in &row.cells {
            if cell.side_bytes() == 0 {
                continue;
            }
            if distinct.iter().any(|seen| seen.shares_side_record(cell)) {
                continue;
            }
            distinct.push(cell);
        }
        let expected = base + distinct.iter().map(|cell| cell.side_bytes()).sum::<usize>();
        assert_eq!(row.bytes_for_test(), expected, "row {row_index} charge", row_index = row.id);
        assert_eq!(row.bytes_for_test(), expected);
    }

    /// Every row's cached charge must equal an independent full recomputation.
    fn assert_charges_exact(term: &Terminal, context: &str) {
        for screen in [&term.main, &term.alternate] {
            for row in screen.rows.iter().chain(&screen.history) {
                assert_eq!(
                    row.bytes_for_test(),
                    row.recount_for_test(),
                    "row {} charge after {context}",
                    row.id
                );
            }
        }
    }

    #[test]
    fn overwrites_edits_and_blank_fills_keep_the_charge_exact() {
        let mut term = Terminal::new(16, 3, 100).unwrap();
        term.enable_grapheme_support(true);
        let steps: &[&[u8]] = &[
            b"\x1b[38;2;1;2;3mtruecolor run",
            b"\x1b[0m plain overwrite",
            b"\x1b[1;1Hback",
            b"\x1b[48;2;9;8;7m\x1b[2K",
            b"\x1b[49m\x1b[1;1H\x1b[2P",
            b"\x1b[1;1H\x1b[3@",
            b"\x1b[1;1H\x1b[4X",
            b"\x1b[1;1H\x1b[0K",
            b"\x1b]8;;https://example.test\x1b\\linked\x1b]8;;\x1b\\",
            "\u{1b}[1;1H中中中".as_bytes(),
            "\u{1b}[1;2He\u{301}".as_bytes(),
            b"\x1b[2;1H\x1b[L\x1b[M",
            b"\x1b[#8",
        ];
        for (index, step) in steps.iter().enumerate() {
            feed(&mut term, step);
            assert_charges_exact(&term, &format!("step {index}"));
        }
    }

    #[test]
    fn reflow_rebuilds_charges_that_match_a_recount() {
        let mut term = Terminal::new(17, 3, 100).unwrap();
        term.enable_grapheme_support(true);
        feed(&mut term, b"\x1b[38;2;4;5;6mabcdefghijklmnopq");
        feed(&mut term, "\u{1b}]8;;https://example.test\u{1b}\\linked text\u{1b}]8;;\u{1b}\\".as_bytes());
        feed(&mut term, b"\x1b[1;1Habcdefghijklmnopqrstuvwxyz0123456789");
        assert_charges_exact(&term, "before resize");
        for (cols, rows) in [(9usize, 4usize), (4, 3), (23, 2), (2, 6), (17, 3)] {
            term.resize(cols, rows, |_| {}).unwrap();
            assert_charges_exact(&term, &format!("resize to {cols}x{rows}"));
            for row in term.main.rows.iter().chain(&term.main.history) {
                let base = row.cells.capacity() * std::mem::size_of::<Cell>();
                assert!(row.bytes_for_test() >= base, "base storage is always charged");
            }
        }
    }

    #[test]
    fn recycled_and_pruned_rows_start_with_an_exact_charge() {
        // A tight history limit forces remember/recycle, reusing row storage that held
        // styled records. A recycled row must not inherit the previous charge.
        let mut term = Terminal::new(12, 2, 3).unwrap();
        for line in 0..24 {
            let styled = format!("\x1b[38;2;{line};0;0mline {line} text\x1b[0m\r\n");
            feed(&mut term, styled.as_bytes());
            assert_charges_exact(&term, &format!("line {line}"));
        }
        assert!(term.screen().history.len() <= 3, "history pruning keeps the bound");
        // Plain rows after styled rows must charge base only, never a stale record.
        for _ in 0..6 {
            feed(&mut term, b"plain rows only\r\n");
        }
        assert_charges_exact(&term, "plain after styled");
        for row in term.screen().history.iter().chain(term.screen().rows.iter()) {
            if row.cells.iter().all(|cell| cell.side_bytes() == 0) {
                let base = row.cells.capacity() * std::mem::size_of::<Cell>();
                assert_eq!(row.bytes_for_test(), base, "a heap-free row is charged base only");
            }
        }
    }

    #[test]
    fn shared_presentation_rows_charge_one_record_not_one_per_cell() {
        // An RGB blank fill and an RGB text run both share a single record across the
        // whole row, so a per-cell charge would bill the row `cols` times for it.
        let mut term = Terminal::new(40, 2, 100).unwrap();
        term.preserve_erased_screen = false;
        feed(&mut term, b"\x1b[48;2;1;2;3m\x1b[2J");
        let row = &term.screen().rows[0];
        let base = row.cells.capacity() * std::mem::size_of::<Cell>();
        let record = row.cells[0].side_bytes();
        assert!(record > 0, "an RGB blank owns a record");
        assert!(row.cells[0].shares_side_record(&row.cells[39]), "the fill shares one record");
        assert_eq!(row.bytes_for_test(), base + record, "one record, not one per cell");
        assert_row_charge_matches_records(&term, 0);

        // The same invariant for a truecolor text row written as one run.
        let mut term = Terminal::new(40, 2, 100).unwrap();
        feed(&mut term, b"\x1b[38;2;9;8;7m");
        feed(&mut term, b"truecolor text on one row");
        let row = &term.screen().rows[0];
        let base = row.cells.capacity() * std::mem::size_of::<Cell>();
        let record = row.cells[0].side_bytes();
        assert_eq!(row.bytes_for_test(), base + record, "one record for the whole run");
        assert_row_charge_matches_records(&term, 0);
    }

    #[test]
    fn distinct_side_records_are_each_charged_once() {
        // One row holding: a shared RGB run, a combining-mark cell and a linked cell.
        let mut term = Terminal::new(40, 2, 100).unwrap();
        feed(&mut term, b"\x1b[38;2;1;2;3mab");
        feed(&mut term, "\u{1b}[0me\u{301}".as_bytes());
        feed(&mut term, b"\x1b]8;;https://example.test\x1b\\L\x1b]8;;\x1b\\");
        feed(&mut term, b"cd");
        let row = &term.screen().rows[0];
        let base = row.cells.capacity() * std::mem::size_of::<Cell>();
        // a and b share the run's record; c and d share it again after the link closes.
        assert!(row.cells[0].shares_side_record(&row.cells[1]));
        assert_ne!(row.cells[0].side_bytes(), 0);
        let distinct: Vec<usize> = {
            let mut sizes: Vec<usize> = Vec::new();
            let mut seen: Vec<&Cell> = Vec::new();
            for cell in &row.cells {
                if cell.side_bytes() == 0 || seen.iter().any(|other| other.shares_side_record(cell)) {
                    continue;
                }
                seen.push(cell);
                sizes.push(cell.side_bytes());
            }
            sizes
        };
        assert!(distinct.len() >= 3, "the row holds at least three distinct records");
        assert_eq!(
            row.bytes_for_test(),
            base + distinct.iter().sum::<usize>(),
            "each distinct record charged once"
        );
        assert_row_charge_matches_records(&term, 0);
        // Charging per cell would have been far larger.
        let per_cell: usize = row.cells.iter().map(Cell::side_bytes).sum();
        assert!(row.bytes_for_test() < base + per_cell, "shared records are deduplicated");
    }

    #[test]
    fn styled_history_is_charged_one_record_per_row() {
        // Scrolling styled rows must not multiply their record by the row width, or the
        // history budget would evict them far earlier than plain rows.
        let mut styled = Terminal::new(60, 2, 100).unwrap();
        let mut plain = Terminal::new(60, 2, 100).unwrap();
        for line in 0..30 {
            let text = format!("\x1b[38;2;1;2;3mrow {line} styled text\x1b[0m\r\n");
            feed(&mut styled, text.as_bytes());
            feed(&mut plain, format!("row {line} styled text\r\n").as_bytes());
        }
        assert!(!styled.screen().history.is_empty());
        assert_eq!(styled.screen().history.len(), plain.screen().history.len());
        // Each history row is charged base + one record, and the totals stay close to
        // the plain rows instead of ~cols times the record.
        for row in &styled.screen().history {
            let base = row.cells.capacity() * std::mem::size_of::<Cell>();
            let record = row.cells[0].side_bytes();
            assert!(record > 0, "styled history rows keep their record");
            assert_eq!(row.bytes_for_test(), base + record, "one record per history row");
        }
        let styled_bytes = styled.screen().history_bytes_for_test();
        let plain_bytes = plain.screen().history_bytes_for_test();
        assert!(
            styled_bytes < plain_bytes * 2,
            "styled history ({styled_bytes}) must not be charged ~cols times the plain total ({plain_bytes})"
        );
    }

    #[test]
    fn rgb_blank_rows_count_their_heap_in_the_history_budget() {
        assert!(Cell::blank_owns_heap(Color::rgb(1, 2, 3)));
        assert!(!Cell::blank_owns_heap(Color::Indexed(4)));
        assert!(!Cell::blank_owns_heap(Color::Background));
        // A blanked row of an RGB background owns a side record per fill, so clearing
        // the heap flag would under-count the history budget and let it be bypassed.
        let mut term = Terminal::new(8, 2, 100).unwrap();
        term.preserve_erased_screen = false;
        feed(&mut term, b"\x1b[48;2;1;2;3m\x1b[2J");
        assert!(term.screen().rows.iter().all(|row| row.cells[0].style().bg == Color::rgb(1, 2, 3)));
        assert!(
            term.screen().rows.iter().all(|row| row.cells[0].side_bytes() > 0),
            "an RGB blank owns heap"
        );
        // Scroll those blank rows into history without writing text.
        feed(&mut term, b"\n\n\n\n");
        assert!(!term.screen().history.is_empty());
        assert!(
            term.screen().history_bytes_for_test() > history_base(&term),
            "RGB blank history rows must count their heap, not base only"
        );
        // The same rows of a packed background stay certifiable as heap-free.
        let mut term = Terminal::new(8, 2, 100).unwrap();
        term.preserve_erased_screen = false;
        feed(&mut term, b"\x1b[44m\x1b[2J\n\n\n\n");
        assert!(!term.screen().history.is_empty());
        assert_eq!(
            term.screen().history_bytes_for_test(),
            history_base(&term),
            "an indexed background is packed, so its blank rows own no heap"
        );
    }

    #[test]
    fn partial_rgb_erases_and_edits_keep_the_history_bound() {
        // Every path that installs a blank must keep the row's heap flag honest. Paint a
        // row with packed blanks first, so a stale `false` would be the only way the
        // RGB blank could go uncounted.
        for escape in ["\x1b[0K", "\x1b[1;3H\x1b[0K", "\x1b[1;1H\x1b[P", "\x1b[1;1H\x1b[2@"] {
            let mut term = Terminal::new(8, 2, 100).unwrap();
            term.preserve_erased_screen = false;
            feed(&mut term, b"\x1b[44m\x1b[2J");
            assert!(term.screen().rows.iter().all(|row| row.cells[0].side_bytes() == 0));
            // Switch to an RGB background and install blanks through the edit path.
            feed(&mut term, b"\x1b[48;2;3;4;5m");
            feed(&mut term, escape.as_bytes());
            // Scroll the blanked row into history without writing text over it.
            feed(&mut term, b"\x1b[1;1H\n\n\n");
            assert!(!term.screen().history.is_empty(), "{escape:?}");
            assert!(
                term.screen().history_bytes_for_test() > history_base(&term),
                "{escape:?} installs RGB blanks that must be counted"
            );
        }
    }

    #[test]
    fn blank_fills_share_one_side_record_instead_of_allocating_per_cell() {
        let mut term = Terminal::new(24, 2, 10).unwrap();
        term.preserve_erased_screen = false;
        feed(&mut term, b"\x1b[48;2;9;8;7m\x1b[2J");
        for row in &term.screen().rows {
            assert!(row.cells[0].side_bytes() > 0, "RGB blanks own a record");
            assert!(
                row.cells[0].shares_side_record(&row.cells[23]),
                "one fill must share a single record across the row"
            );
        }
        // A full-line erase into the same background is also one fill, so the cells of
        // the rewritten row still share a single record across the whole width.
        feed(&mut term, b"\x1b[2K");
        let row = &term.screen().rows[0];
        assert!(row.cells[0].side_bytes() > 0);
        assert!(
            (1..row.cells.len()).all(|col| row.cells[0].shares_side_record(&row.cells[col])),
            "one erase fill must share a single record across the row"
        );
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
