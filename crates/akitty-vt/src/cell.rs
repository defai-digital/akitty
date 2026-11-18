//! Portable cell content and presentation. Numeric color indices are protocol data.
//!
//! An ordinary cell is 16 bytes: the character, one packed word holding the common
//! presentation plus the width and written flags, and an optional shared side record.
//! Combining marks, hyperlinks and presentation the packed word cannot represent
//! (RGB colours, underline colours) live in that record. Cells written in one run
//! share a prepared [`CellStyle`], so ordinary text owns no per-cell heap and an
//! RGB or hyperlinked run costs one record instead of one allocation per cell.
//!
//! Callers read values through accessors (`style`, `width`, `written`, `combining`);
//! `ch` stays a plain character field because every consumer reads it as one.

use std::sync::Arc;

pub const BOLD: u16 = 1;
pub const ITALIC: u16 = 2;
pub const FAINT: u16 = 4;
pub const INVERSE: u16 = 8;
pub const INVISIBLE: u16 = 16;
pub const STRIKE: u16 = 32;
pub const BLINK: u16 = 64;
pub const MAX_COMBINING: usize = 16;
/// Combining storage reserved when a cell first takes marks. Common emoji families and
/// stacked diacritics add a handful, so one small allocation avoids the 1-2-4 growth
/// copies. It stays far under [`MAX_COMBINING`], and heap accounting reads the real
/// capacity, so the reservation is charged honestly.
const COMBINING_RESERVE: usize = 8;

/// Bits 0..=6 of [`Style::attrs`] are the only attributes the packed word carries.
const ATTRS_BITS: u32 = 0x7f;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Color {
    #[default]
    Foreground,
    Background,
    Indexed(u8),
    Rgb([u8; 3]),
}

impl Color {
    pub fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self::Rgb([r, g, b])
    }
    pub fn pack(rgb: [u8; 3]) -> u32 {
        u32::from(rgb[0]) << 16 | u32::from(rgb[1]) << 8 | u32::from(rgb[2])
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Style {
    pub fg: Color,
    pub bg: Color,
    pub attrs: u16,
    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    pub underline: u8,
    pub underline_color: Option<Color>,
}

impl Default for Style {
    fn default() -> Self {
        Self {
            fg: Color::Foreground,
            bg: Color::Background,
            attrs: 0,
            underline: 0,
            underline_color: None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct Link {
    pub id: u32,
    pub uri: Box<str>,
}

/// Field layout of the packed presentation word.
///
/// | bits    | field                                                     |
/// |---------|-----------------------------------------------------------|
/// | 0..=8   | foreground: 0..=255 palette, 256 default, 511 see record   |
/// | 9..=17  | background: same encoding                                  |
/// | 18..=24 | attribute flags                                            |
/// | 25..=27 | underline style                                            |
/// | 28..=29 | column width: 0 trailing half, 1, 2                         |
/// | 30      | written                                                    |
/// | 31      | unused, kept clear                                         |
const FG_MASK: u32 = 0x1ff;
const BG_SHIFT: u32 = 9;
const BG_MASK: u32 = 0x1ff << BG_SHIFT;
const ATTRS_SHIFT: u32 = 18;
const ATTRS_MASK: u32 = ATTRS_BITS << ATTRS_SHIFT;
const UNDERLINE_SHIFT: u32 = 25;
const UNDERLINE_MASK: u32 = 0x7 << UNDERLINE_SHIFT;
const WIDTH_SHIFT: u32 = 28;
const WIDTH_MASK: u32 = 0x3 << WIDTH_SHIFT;
const WRITTEN: u32 = 1 << 30;

/// `Color::Foreground` in a packed colour field.
const PACKED_FOREGROUND: u16 = 256;
/// `Color::Background` in a packed colour field.
const PACKED_BACKGROUND: u16 = 257;
/// "This colour needs the side record": RGB, or a role colour in the other slot.
const PACKED_RARE: u16 = 511;

/// Encode a colour into a packed field, or [`PACKED_RARE`] when it cannot be inline.
fn pack_color(color: Color) -> u16 {
    match color {
        Color::Foreground => PACKED_FOREGROUND,
        Color::Background => PACKED_BACKGROUND,
        Color::Indexed(index) => u16::from(index),
        Color::Rgb(_) => PACKED_RARE,
    }
}

/// Decode a packed colour field. Only called when the field is not [`PACKED_RARE`].
fn unpack_color(field: u16) -> Color {
    match field {
        PACKED_FOREGROUND => Color::Foreground,
        PACKED_BACKGROUND => Color::Background,
        index => Color::Indexed(index as u8),
    }
}

/// Presentation that the packed word cannot hold, or a hyperlink, or both.
/// Cells written in one run share one record; a record never owns combining marks
/// while it is shared as a style template.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct CellExtras {
    combining: Vec<char>,
    link: Option<Arc<Link>>,
    style: Option<Style>,
}

impl CellExtras {
    fn heap_bytes(&self) -> usize {
        std::mem::size_of::<CellExtras>()
            + self.combining.capacity() * std::mem::size_of::<char>()
            + self
                .link
                .as_ref()
                .map_or(0, |link| std::mem::size_of::<Link>() + link.uri.len())
    }
}

/// One grid cell: 16 bytes for the common case.
#[derive(Clone, Debug)]
pub struct Cell {
    pub ch: char,
    packed: u32,
    extras: Option<Arc<CellExtras>>,
}

impl PartialEq for Cell {
    /// Compares the values a host can observe, not the internal sharing: two cells
    /// with the same character, presentation, width, written flag, combining marks
    /// and hyperlink are equal whether or not their side records are shared.
    fn eq(&self, other: &Self) -> bool {
        self.ch == other.ch
            && self.width() == other.width()
            && self.written() == other.written()
            && self.style() == other.style()
            && self.combining() == other.combining()
            && match (self.link(), other.link()) {
                (None, None) => true,
                (Some(a), Some(b)) => a.id == b.id && a.uri == b.uri,
                _ => false,
            }
    }
}

impl Eq for Cell {}

impl Default for Cell {
    fn default() -> Self {
        Self::blank(Color::Background)
    }
}

impl Cell {
    /// A blank cell with `bg` behind it: what every erase and row reset installs.
    pub fn blank(bg: Color) -> Self {
        let encoded = pack_color(bg);
        let extras = (encoded == PACKED_RARE).then(|| {
            Arc::new(CellExtras {
                combining: Vec::new(),
                link: None,
                style: Some(Style { bg, ..Style::default() }),
            })
        });
        let packed = u32::from(PACKED_FOREGROUND) | u32::from(encoded) << BG_SHIFT | 1 << WIDTH_SHIFT;
        Self { ch: ' ', packed, extras }
    }
    /// Whether [`Cell::blank`] of `bg` owns a side record. An RGB background cannot be
    /// packed, so blank cells of that colour hold heap and their row must keep counting
    /// it in the history budget.
    #[inline]
    pub(crate) fn blank_owns_heap(bg: Color) -> bool {
        pack_color(bg) == PACKED_RARE
    }
    /// Whether two cells share one side record. Test-only: it proves a blank fill shares
    /// a single record instead of allocating one per cell.
    #[cfg(test)]
    pub(crate) fn shares_side_record(&self, other: &Self) -> bool {
        match (&self.extras, &other.extras) {
            (Some(left), Some(right)) => Arc::ptr_eq(left, right),
            _ => false,
        }
    }
    /// A cell from an already prepared packed word and no side record: the store the
    /// batched ASCII path repeats.
    #[inline]
    pub(crate) fn from_packed(ch: char, packed: u32) -> Self {
        Self { ch, packed, extras: None }
    }
    /// A written single-column cell in the default presentation (DECALN fill).
    pub(crate) fn plain(ch: char) -> Self {
        Self {
            ch,
            packed: u32::from(PACKED_FOREGROUND)
                | u32::from(PACKED_BACKGROUND) << BG_SHIFT
                | 1 << WIDTH_SHIFT
                | WRITTEN,
            extras: None,
        }
    }
    /// Presentation of this cell; the side record wins when it holds one.
    #[inline]
    pub fn style(&self) -> Style {
        if let Some(record) = &self.extras
            && let Some(style) = record.style
        {
            return style;
        }
        let word = self.packed;
        Style {
            fg: unpack_color((word & FG_MASK) as u16),
            bg: unpack_color(((word & BG_MASK) >> BG_SHIFT) as u16),
            attrs: ((word & ATTRS_MASK) >> ATTRS_SHIFT) as u16,
            underline: ((word & UNDERLINE_MASK) >> UNDERLINE_SHIFT) as u8,
            underline_color: None,
        }
    }
    /// 0 is the trailing column of a wide character, otherwise 1 or 2.
    #[inline]
    pub fn width(&self) -> u8 {
        ((self.packed & WIDTH_MASK) >> WIDTH_SHIFT) as u8
    }
    #[inline]
    pub fn written(&self) -> bool {
        self.packed & WRITTEN != 0
    }
    #[inline]
    pub fn combining(&self) -> &[char] {
        self.extras.as_ref().map_or(&[], |record| record.combining.as_slice())
    }
    #[inline]
    pub fn combining_len(&self) -> usize {
        self.extras.as_ref().map_or(0, |record| record.combining.len())
    }
    #[inline]
    pub fn link(&self) -> Option<&Arc<Link>> {
        self.extras.as_ref().and_then(|record| record.link.as_ref())
    }
    pub fn link_id(&self) -> u32 {
        self.link().map_or(0, |link| link.id)
    }
    pub fn link_uri(&self) -> Option<&str> {
        self.link().map(|link| &*link.uri)
    }
    pub fn text(&self) -> String {
        if self.width() == 0 {
            return String::new();
        }
        let mut text = String::from(self.ch);
        text.extend(self.combining());
        text
    }
    pub fn occupied(&self) -> bool {
        self.ch != ' '
            || self.combining_len() != 0
            || self.width() != 1
            || self.style() != Style::default()
            || self.link().is_some()
    }
    /// Heap bytes this cell's side record occupies, for accounting tests. Rows account
    /// with [`side_bytes`], which counts a record shared by a run only once.
    #[cfg(test)]
    pub(crate) fn side_bytes(&self) -> usize {
        self.extras.as_ref().map_or(0, |record| record.heap_bytes())
    }
    /// Combining storage capacity, for tests that prove the first append reserves once.
    #[cfg(test)]
    pub(crate) fn combining_capacity(&self) -> usize {
        self.extras.as_ref().map_or(0, |record| record.combining.capacity())
    }
    #[inline]
    pub(crate) fn set_width(&mut self, width: u8) {
        self.packed = (self.packed & !WIDTH_MASK) | (u32::from(width & 3) << WIDTH_SHIFT);
    }
    #[inline]
    pub(crate) fn set_written(&mut self, written: bool) {
        self.packed = if written { self.packed | WRITTEN } else { self.packed & !WRITTEN };
    }
    /// Attach a combining mark; `false` when the per-cell bound is already reached.
    pub(crate) fn push_combining(&mut self, ch: char) -> bool {
        if self.combining_len() >= MAX_COMBINING {
            return false;
        }
        let record = self.extras.get_or_insert_with(|| {
            Arc::new(CellExtras {
                combining: Vec::with_capacity(COMBINING_RESERVE),
                ..CellExtras::default()
            })
        });
        let record = Arc::make_mut(record);
        // A record reached through a shared style template starts with no mark storage,
        // so the reservation happens on the append that first adds one.
        if record.combining.capacity() < COMBINING_RESERVE {
            record.combining.reserve_exact(COMBINING_RESERVE - record.combining.len());
        }
        record.combining.push(ch);
        true
    }
    /// The trailing column of a wide glyph: same presentation and hyperlink, no
    /// character, no combining marks, not written.
    pub(crate) fn spacer(&self) -> Self {
        let extras = match &self.extras {
            Some(record) if record.combining.is_empty() => Some(Arc::clone(record)),
            // Marks never move to the trailing half. When the record holds nothing but
            // those marks the spacer needs no side record at all: its character is blank,
            // its width is zero, and the packed word already carries its presentation, so
            // a wide emoji cluster stops allocating a record for its second column.
            Some(record) if record.link.is_none() && record.style.is_none() => None,
            Some(record) => Some(Arc::new(CellExtras {
                combining: Vec::new(),
                link: record.link.clone(),
                style: record.style,
            })),
            None => None,
        };
        Self { ch: ' ', packed: self.packed & !(WIDTH_MASK | WRITTEN), extras }
    }
}

/// Heap charged for a row's side records: each distinct record once.
///
/// Cells written in one run share a single record, so charging per cell would bill a
/// row `cols` times for one record and evict history far too early. A record shared
/// with other rows is charged again in each of them: a conservative upper bound that
/// never under-counts, without any cross-row tracking.
pub(crate) fn side_bytes(cells: &[Cell]) -> usize {
    /// Records remembered without allocating. A row normally holds one to three: the
    /// presentation of its runs, plus a few cells with combining marks or links.
    const SCRATCH: usize = 8;
    let mut seen: [Option<&Arc<CellExtras>>; SCRATCH] = [None; SCRATCH];
    let mut held = 0;
    let mut total = 0;
    for (index, cell) in cells.iter().enumerate() {
        let Some(record) = cell.extras.as_ref() else { continue };
        let known = if held < SCRATCH {
            seen[..held].iter().flatten().any(|other| Arc::ptr_eq(*other, record))
        } else {
            // Past the scratch, stay exact and still allocation-free by comparing
            // against the cells already seen.
            cells[..index].iter().any(|earlier| {
                earlier.extras.as_ref().is_some_and(|other| Arc::ptr_eq(other, record))
            })
        };
        if known {
            continue;
        }
        total += record.heap_bytes();
        if held < SCRATCH {
            seen[held] = Some(record);
            held += 1;
        }
    }
    total
}

/// Prepared presentation for a run of writes. Building one packs the colours once and
/// creates a single side record, so every cell of the run shares it.
#[derive(Clone, Debug)]
pub(crate) struct CellStyle {
    /// Colours, attributes and underline style; width and written are clear.
    packed: u32,
    extras: Option<Arc<CellExtras>>,
}

impl CellStyle {
    pub(crate) fn new(style: &Style, link: Option<&Arc<Link>>) -> Self {
        let fg = pack_color(style.fg);
        let bg = pack_color(style.bg);
        let rare = fg == PACKED_RARE
            || bg == PACKED_RARE
            || style.underline_color.is_some()
            || style.attrs & !(ATTRS_BITS as u16) != 0
            || style.underline > 5;
        let packed = u32::from(if rare { PACKED_RARE } else { fg })
            | u32::from(if rare { PACKED_RARE } else { bg }) << BG_SHIFT
            | u32::from(style.attrs & ATTRS_BITS as u16) << ATTRS_SHIFT
            | u32::from(style.underline.min(7)) << UNDERLINE_SHIFT;
        let extras = (rare || link.is_some()).then(|| {
            Arc::new(CellExtras {
                combining: Vec::new(),
                link: link.cloned(),
                style: rare.then_some(*style),
            })
        });
        Self { packed, extras }
    }
    /// One cell of this presentation. The side record is shared by reference.
    #[inline]
    pub(crate) fn cell(&self, ch: char, width: u8, written: bool) -> Cell {
        let mut packed = (self.packed & !(WIDTH_MASK | WRITTEN))
            | (u32::from(width & 3) << WIDTH_SHIFT);
        if written {
            packed |= WRITTEN;
        }
        Cell { ch, packed, extras: self.extras.clone() }
    }
    /// Whether cells of this presentation own a side record (link or rare style).
    #[inline]
    pub(crate) fn has_side_data(&self) -> bool {
        self.extras.is_some()
    }
    /// Identity and heap size of this template's side record, for a row's incremental
    /// charge. The identity is only ever compared, never dereferenced, and a row keeps
    /// using a key only while one of its cells still holds that record.
    #[inline]
    pub(crate) fn side_identity(&self) -> Option<(usize, usize)> {
        self.extras
            .as_ref()
            .map(|record| (Arc::as_ptr(record) as usize, record.heap_bytes()))
    }
    /// Packed word for a written single-column cell of this presentation.
    #[inline]
    pub(crate) fn packed_written_column(&self) -> u32 {
        (self.packed & !(WIDTH_MASK | WRITTEN)) | (1 << WIDTH_SHIFT) | WRITTEN
    }
    /// A written single-column cell of this presentation, sharing the side record.
    #[inline]
    pub(crate) fn written_column(&self, ch: char) -> Cell {
        let packed = self.packed_written_column();
        match &self.extras {
            Some(record) => Cell { ch, packed, extras: Some(Arc::clone(record)) },
            None => Cell { ch, packed, extras: None },
        }
    }
}

#[derive(Clone, Debug)]
pub struct Palette {
    overrides: [Option<u32>; 259],
    configured: [Option<u32>; 259],
    pub foreground: u32,
    pub background: u32,
}

impl Default for Palette {
    fn default() -> Self {
        Self {
            overrides: [None; 259],
            configured: [None; 259],
            foreground: 0xdae2ef,
            background: 0x080a0d,
        }
    }
}

impl Palette {
    pub fn resolve(&self, color: Color) -> u32 {
        match color {
            Color::Foreground => self.overrides[256]
                .or(self.configured[256])
                .unwrap_or(self.foreground),
            Color::Background => self.overrides[257]
                .or(self.configured[257])
                .unwrap_or(self.background),
            Color::Indexed(index) => self.overrides[usize::from(index)]
                .or(self.configured[usize::from(index)])
                .unwrap_or_else(|| Self::indexed(index)),
            Color::Rgb(rgb) => Color::pack(rgb),
        }
    }
    pub fn cursor(&self) -> Option<u32> {
        self.overrides[258].or(self.configured[258])
    }
    pub fn set(&mut self, index: usize, color: Option<u32>) {
        if let Some(slot) = self.overrides.get_mut(index) {
            *slot = color;
        }
    }
    /// Host theme is the reset baseline; OSC colors are temporary overrides.
    pub fn configure(&mut self, index: usize, color: u32) {
        if let Some(slot) = self.configured.get_mut(index) {
            *slot = Some(color);
        }
    }
    pub fn reset(&mut self) {
        self.overrides.fill(None);
    }
    /// Drop the host theme so the built-in colours become the reset baseline again.
    pub fn clear_configured(&mut self) {
        self.configured.fill(None);
    }
    /// The host theme's default background, ignoring temporary OSC 11 overrides: the colour a
    /// host clears its frame to.
    pub fn base_background(&self) -> u32 {
        self.configured[257].unwrap_or(self.background)
    }
    pub fn indexed(index: u8) -> u32 {
        const ANSI: [u32; 16] = [
            0x161a21, 0xed646d, 0x8fca8d, 0xe5c07b, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xcbd5e1,
            0x535d6f, 0xff7b84, 0xa9e29d, 0xffda91, 0x97b7ff, 0xd3b1ff, 0x9de9ff, 0xf1f5f9,
        ];
        if index < 16 {
            return ANSI[usize::from(index)];
        }
        if index >= 232 {
            let gray = u32::from(8 + (index - 232) * 10);
            return gray * 0x010101;
        }
        let n = u32::from(index - 16);
        let channel = |x| if x == 0 { 0 } else { 55 + x * 40 };
        channel(n / 36) << 16 | channel(n / 6 % 6) << 8 | channel(n % 6)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cell_layout_stays_compact() {
        assert_eq!(std::mem::size_of::<Color>(), 4);
        assert_eq!(std::mem::size_of::<Option<Color>>(), 4);
        assert!(
            std::mem::size_of::<Style>() <= 16,
            "{}",
            std::mem::size_of::<Style>()
        );
        assert_eq!(std::mem::size_of::<Cell>(), 16);
    }

    #[test]
    fn packed_presentation_round_trips_every_common_style() {
        let mut styles = vec![Style::default()];
        for index in [0u8, 1, 7, 15, 16, 231, 232, 255] {
            styles.push(Style { fg: Color::Indexed(index), ..Style::default() });
            styles.push(Style { bg: Color::Indexed(index), ..Style::default() });
        }
        for attrs in 0..=u16::from(u8::MAX) {
            styles.push(Style { attrs: attrs & 0x7f, ..Style::default() });
        }
        for underline in 0..=5u8 {
            styles.push(Style { underline, ..Style::default() });
        }
        styles.push(Style { fg: Color::Background, bg: Color::Foreground, ..Style::default() });
        let template = |style: &Style| CellStyle::new(style, None).cell('x', 1, true);
        for style in styles {
            let cell = template(&style);
            assert_eq!(cell.style(), style, "{style:?} must survive the packed word");
            assert_eq!(cell.width(), 1);
            assert!(cell.written());
            assert!(cell.combining().is_empty());
            assert!(cell.link().is_none());
        }
        // Anything the packed word cannot hold keeps the whole style in the side record.
        for style in [
            Style { fg: Color::rgb(1, 2, 3), ..Style::default() },
            Style { bg: Color::rgb(250, 0, 9), ..Style::default() },
            Style { underline_color: Some(Color::rgb(4, 5, 6)), underline: 3, ..Style::default() },
            Style { underline_color: Some(Color::Indexed(9)), ..Style::default() },
        ] {
            let cell = template(&style);
            assert_eq!(cell.style(), style, "{style:?} must survive the side record");
        }
    }

    #[test]
    fn blank_cells_carry_only_the_requested_background() {
        for bg in [
            Color::Background,
            Color::Indexed(4),
            Color::rgb(9, 8, 7),
            Color::Foreground,
        ] {
            let cell = Cell::blank(bg);
            assert_eq!(cell.ch, ' ');
            assert_eq!(cell.style(), Style { bg, ..Style::default() });
            assert_eq!(cell.width(), 1);
            assert!(!cell.written());
            assert_eq!(cell.text(), " ");
            assert_eq!(cell.occupied(), bg != Color::Background);
        }
        assert_eq!(Cell::default(), Cell::blank(Color::Background));
    }

    #[test]
    fn a_run_shares_one_side_record_and_combining_detaches_it() {
        let link = Arc::new(Link { id: 7, uri: "https://example.test".into() });
        let style = Style { fg: Color::rgb(1, 2, 3), ..Style::default() };
        let template = CellStyle::new(&style, Some(&link));
        assert!(template.has_side_data());
        let first = template.cell('a', 1, true);
        let second = template.cell('b', 1, true);
        assert_eq!(first.link_uri(), Some("https://example.test"));
        assert!(Arc::ptr_eq(first.link().unwrap(), second.link().unwrap()));
        assert_eq!(template.cell('a', 1, true).side_bytes(), first.side_bytes());
        // A combining mark must not leak into other cells of the same run.
        let mut marked = first.clone();
        assert!(marked.push_combining('\u{301}'));
        assert_eq!(marked.combining(), &['\u{301}']);
        assert_eq!(marked.link_uri(), Some("https://example.test"));
        assert_eq!(marked.style(), style);
        assert!(second.combining().is_empty());
        assert_eq!(first.combining(), &[] as &[char]);
    }

    #[test]
    fn spacers_keep_presentation_without_content() {
        let style = Style { fg: Color::Indexed(2), underline: 1, ..Style::default() };
        let link = Arc::new(Link { id: 3, uri: "https://spacer.test".into() });
        let lead = CellStyle::new(&style, Some(&link)).cell('中', 2, true);
        let spacer = lead.spacer();
        assert_eq!(spacer.ch, ' ');
        assert_eq!(spacer.width(), 0);
        assert!(!spacer.written());
        assert_eq!(spacer.style(), style);
        assert_eq!(spacer.link_uri(), Some("https://spacer.test"));
        assert!(spacer.combining().is_empty());
        assert_eq!(spacer.text(), "");
        // A lead that owns combining marks cannot share them with the trailing half.
        let mut marked = lead.clone();
        assert!(marked.push_combining('\u{301}'));
        let detached = marked.spacer();
        assert!(detached.combining().is_empty());
        assert_eq!(marked.combining(), &['\u{301}']);
    }

    #[test]
    fn combining_marks_are_bounded_per_cell() {
        let mut cell = Cell::default();
        for _ in 0..MAX_COMBINING {
            assert!(cell.push_combining('\u{301}'));
        }
        assert!(!cell.push_combining('\u{301}'));
        assert_eq!(cell.combining_len(), MAX_COMBINING);
        assert!(cell.occupied());
    }

    #[test]
    fn a_marked_plain_lead_gives_a_spacer_without_a_side_record() {
        // A wide emoji cluster: the lead holds marks and nothing else. The trailing column
        // carries presentation the packed word already represents, so it needs no record.
        let mut lead = Cell::plain('中');
        lead.set_width(2);
        lead.set_written(true);
        assert!(lead.push_combining('\u{301}'));
        assert!(lead.side_bytes() > 0, "the lead still owns its marks");
        let spacer = lead.spacer();
        assert_eq!(spacer.ch, ' ');
        assert_eq!(spacer.width(), 0);
        assert!(!spacer.written());
        assert!(spacer.combining().is_empty(), "marks never move to the trailing half");
        assert_eq!(spacer.side_bytes(), 0, "no empty record for a plain trailing half");
        assert_eq!(spacer.style(), lead.style());
        assert_eq!(spacer.link_uri(), None);
        assert_eq!(spacer.text(), "");
        // Removing the record must not become visible through equality.
        let mut expected = Cell::plain(' ');
        expected.set_width(0);
        expected.set_written(false);
        assert_eq!(spacer, expected);
    }

    #[test]
    fn a_marked_lead_keeps_link_and_rare_presentation_on_the_spacer() {
        // A link lives only in the record, so the trailing half must keep one.
        let link = Arc::new(Link { id: 9, uri: "https://spacer.test".into() });
        let mut linked = CellStyle::new(&Style::default(), Some(&link)).cell('中', 2, true);
        assert!(linked.push_combining('\u{301}'));
        let spacer = linked.spacer();
        assert_eq!(spacer.link_uri(), Some("https://spacer.test"));
        assert!(spacer.side_bytes() > 0, "the link must survive on the trailing half");
        assert!(spacer.combining().is_empty());
        assert_eq!(spacer.style(), linked.style());
        // Rare presentation (an RGB colour) also lives in the record, not the packed word.
        let rare = Style { fg: Color::rgb(1, 2, 3), ..Style::default() };
        let mut rare_lead = CellStyle::new(&rare, None).cell('中', 2, true);
        assert!(rare_lead.push_combining('\u{301}'));
        let spacer = rare_lead.spacer();
        assert_eq!(spacer.style(), rare, "an unpackable colour must survive");
        assert_eq!(spacer.link_uri(), None);
        assert!(spacer.side_bytes() > 0, "the rare colour must survive");
        assert!(spacer.combining().is_empty());
    }

    #[test]
    fn the_first_mark_reserves_one_small_bounded_allocation() {
        // One reservation serves a common emoji family instead of 1-2-4 growth copies.
        let mut cell = Cell::default();
        assert_eq!(cell.combining_capacity(), 0, "an untouched cell owns no storage");
        assert!(cell.push_combining('\u{301}'));
        let capacity = cell.combining_capacity();
        assert!(capacity >= COMBINING_RESERVE, "{capacity} reserved for the first mark");
        assert!(capacity <= MAX_COMBINING, "{capacity} must stay inside the cell bound");
        assert_eq!(cell.combining_len(), 1);
        let charged = cell.side_bytes();
        assert_eq!(
            charged,
            std::mem::size_of::<CellExtras>() + capacity * std::mem::size_of::<char>(),
            "heap accounting charges the real capacity, not the length"
        );
        // A record reached through a shared template reserves on its first append too.
        let link = Arc::new(Link { id: 1, uri: "https://template.test".into() });
        let template = CellStyle::new(&Style::default(), Some(&link));
        let mut shared = template.cell('a', 1, true);
        assert_eq!(shared.combining_capacity(), 0, "a template carries no mark storage");
        assert!(shared.push_combining('\u{301}'));
        assert!(shared.combining_capacity() >= COMBINING_RESERVE);
        assert_eq!(shared.combining(), &['\u{301}']);
        assert_eq!(shared.link_uri(), Some("https://template.test"));
        // The per-cell bound still wins: the reservation never widens it.
        for _ in 0..MAX_COMBINING {
            shared.push_combining('\u{302}');
        }
        assert_eq!(shared.combining_len(), MAX_COMBINING);
        assert!(!shared.push_combining('\u{302}'));
        assert!(shared.combining_capacity() <= MAX_COMBINING);
    }

    #[test]
    fn equality_ignores_side_record_sharing_but_not_content() {
        let shared = Arc::new(CellExtras {
            combining: vec!['\u{301}'],
            link: Some(Arc::new(Link { id: 1, uri: "https://a.test".into() })),
            style: None,
        });
        let mut left = Cell::plain('e');
        left.extras = Some(Arc::clone(&shared));
        let mut right = Cell::plain('e');
        right.extras = Some(Arc::new(CellExtras {
            combining: vec!['\u{301}'],
            link: Some(Arc::new(Link { id: 1, uri: "https://a.test".into() })),
            style: None,
        }));
        assert_eq!(left, right);
        right.push_combining('\u{302}');
        right.set_written(true);
        assert_ne!(left, right);
    }
}
