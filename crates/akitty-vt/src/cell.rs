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
/// Marks stored inside the side record itself. Common clusters need no second allocation;
/// only the less common ninth through sixteenth marks spill into separate vector storage.
const COMBINING_INLINE: usize = 8;

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

#[derive(Clone, Default)]
enum Combining {
    #[default]
    Empty,
    Inline { len: u8, chars: [char; COMBINING_INLINE] },
    Heap { len: u8, chars: Box<[char; MAX_COMBINING]> },
}

impl Combining {
    fn as_slice(&self) -> &[char] {
        match self {
            Self::Empty => &[],
            Self::Inline { len, chars } => &chars[..usize::from(*len)],
            Self::Heap { len, chars } => &chars[..usize::from(*len)],
        }
    }
    fn len(&self) -> usize {
        self.as_slice().len()
    }
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    #[cfg(test)]
    fn capacity(&self) -> usize {
        match self {
            Self::Empty => 0,
            Self::Inline { .. } => COMBINING_INLINE,
            Self::Heap { .. } => MAX_COMBINING,
        }
    }
    fn spilled_bytes(&self) -> usize {
        match self {
            Self::Heap { .. } => std::mem::size_of::<[char; MAX_COMBINING]>(),
            _ => 0,
        }
    }
    fn push(&mut self, ch: char) {
        match self {
            Self::Empty => {
                let mut chars = ['\0'; COMBINING_INLINE];
                chars[0] = ch;
                *self = Self::Inline { len: 1, chars };
            }
            Self::Inline { len, chars } if usize::from(*len) < COMBINING_INLINE => {
                chars[usize::from(*len)] = ch;
                *len += 1;
            }
            Self::Inline { chars, .. } => {
                let mut spilled = Box::new(['\0'; MAX_COMBINING]);
                spilled[..COMBINING_INLINE].copy_from_slice(chars);
                spilled[COMBINING_INLINE] = ch;
                *self = Self::Heap { len: (COMBINING_INLINE + 1) as u8, chars: spilled };
            }
            Self::Heap { len, chars } => {
                debug_assert!(usize::from(*len) < MAX_COMBINING);
                chars[usize::from(*len)] = ch;
                *len += 1;
            }
        }
    }
}

impl PartialEq for Combining {
    fn eq(&self, other: &Self) -> bool {
        self.as_slice() == other.as_slice()
    }
}
impl Eq for Combining {}
impl std::fmt::Debug for Combining {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.as_slice().fmt(formatter)
    }
}

/// Presentation that the packed word cannot hold, or a hyperlink, or both.
/// Cells written in one run share one record; a record never owns combining marks
/// while it is shared as a style template.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct CellExtras {
    combining: Combining,
    link: Option<Arc<Link>>,
    style: Option<Style>,
}

impl CellExtras {
    fn heap_bytes(&self) -> usize {
        std::mem::size_of::<CellExtras>()
            + self.combining.spilled_bytes()
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

/// The bytes of a cell without a side record, which is then plain data: a character,
/// a packed word and a null record pointer, sixteen bytes with no padding on 64-bit
/// targets.
#[cfg(target_pointer_width = "64")]
#[inline]
fn cell_image(cell: &Cell) -> u128 {
    const _: () = assert!(std::mem::size_of::<Cell>() == std::mem::size_of::<u128>());
    assert!(cell.extras.is_none(), "cell image with a side record");
    // SAFETY: the sizes match and the cell has no padding; reading its bytes copies no
    // ownership because its record pointer is null.
    unsafe { std::mem::transmute_copy(cell) }
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
                combining: Combining::default(),
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
    /// The packed word of a cell without a side record, so a heap-free fill can rebuild
    /// it with `from_packed`.
    #[inline]
    pub(crate) fn packed_word(&self) -> Option<u32> {
        self.extras.is_none().then_some(self.packed)
    }
    /// Overwrite a cell that owns no side record without running its destructor, so a
    /// run of such stores is a plain, vectorizable copy. Callers use it only on rows
    /// whose heap flag certifies every cell heap-free. A wrong caller would leak a side
    /// record rather than corrupt memory; tests assert the precondition.
    #[inline(always)]
    pub(crate) fn store_heap_free(&mut self, value: Cell) {
        debug_assert!(self.extras.is_none(), "heap-free store over a side record");
        std::mem::forget(std::mem::replace(self, value));
    }
    /// Fill `cells` with copies of `value` when neither owns a side record. Such a cell
    /// is plain data, so each copy is one 16-byte store of the same image, which the
    /// compiler turns into a pattern fill; element-wise assignment stores the fields
    /// separately.
    pub(crate) fn fill_heap_free(cells: &mut [Cell], value: &Cell) {
        assert!(value.extras.is_none(), "heap-free fill with a side record");
        debug_assert!(cells.iter().all(|cell| cell.extras.is_none()), "heap-free fill over a side record");
        #[cfg(target_pointer_width = "64")]
        {
            let image = cell_image(value);
            for cell in cells {
                // SAFETY: the target owns no side record, so overwriting it without
                // running its destructor leaks nothing; `image` is a whole `Cell`.
                unsafe { std::ptr::write_unaligned((cell as *mut Cell).cast::<u128>(), image) };
            }
        }
        #[cfg(not(target_pointer_width = "64"))]
        for cell in cells {
            cell.store_heap_free(Cell::from_packed(value.ch, value.packed));
        }
    }
    /// Store the ASCII `bytes` as cells of the packed presentation `packed` over `cells`,
    /// none of which owns a side record. On 64-bit targets each cell is one 16-byte
    /// store of an image whose character field is filled in arithmetically; the field's
    /// position is taken from two reference cells, so no field order is assumed.
    pub(crate) fn store_ascii_heap_free(cells: &mut [Cell], bytes: &[u8], packed: u32) {
        debug_assert!(cells.iter().all(|cell| cell.extras.is_none()), "heap-free store over a side record");
        debug_assert!(bytes.is_ascii());
        #[cfg(target_pointer_width = "64")]
        {
            let base = cell_image(&Cell::from_packed('\0', packed));
            let unit = cell_image(&Cell::from_packed('\u{1}', packed)) ^ base;
            for (cell, &byte) in cells.iter_mut().zip(bytes) {
                // SAFETY: the target owns no side record, so overwriting it leaks nothing.
                // The image differs from `base` only in the character field, which holds
                // `byte`, so it is the whole cell `from_packed(byte, packed)`.
                unsafe {
                    std::ptr::write_unaligned((cell as *mut Cell).cast::<u128>(), base | (u128::from(byte) * unit));
                }
            }
        }
        #[cfg(not(target_pointer_width = "64"))]
        for (cell, &byte) in cells.iter_mut().zip(bytes) {
            cell.store_heap_free(Cell::from_packed(char::from(byte), packed));
        }
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
    /// Inline or spilled capacity, for tests that check the storage boundary and charge.
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
    #[cfg(test)]
    pub(crate) fn push_combining(&mut self, ch: char) -> bool {
        self.push_combining_from(ch, &mut RecordPool::default())
    }
    /// `push_combining`, taking a new side record from `pool` when one is needed.
    pub(crate) fn push_combining_from(&mut self, ch: char, pool: &mut RecordPool) -> bool {
        if self.combining_len() >= MAX_COMBINING {
            return false;
        }
        if self.extras.is_none() {
            let mut record = pool.take();
            Arc::get_mut(&mut record).expect("pooled records are unshared").combining.push(ch);
            self.extras = Some(record);
            return true;
        }
        Arc::make_mut(self.extras.as_mut().expect("a record exists")).combining.push(ch);
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
                combining: Combining::default(),
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

/// Empty side records kept for reuse, so a row that is blanked and written again does
/// not free and allocate a record for every cluster. Only records with no other owner
/// enter it, and they are emptied on the way in, so a pooled record holds no link and
/// no marks. It keeps at most `RecordPool::LIMIT` records.
#[derive(Debug, Default)]
pub(crate) struct RecordPool {
    records: Vec<Arc<CellExtras>>,
}

impl RecordPool {
    pub(crate) const LIMIT: usize = 16;
    /// Take `cell`'s side record into the pool when nothing else shares it and there
    /// is room; otherwise drop the cell's reference. The cell is left without one.
    pub(crate) fn keep(&mut self, cell: &mut Cell) {
        // A plain load rules out shared records (a run's template) before the
        // uniqueness check, which is a compare-and-swap.
        if let Some(mut record) = cell.extras.take()
            && self.records.len() < Self::LIMIT
            && Arc::strong_count(&record) == 1
            && let Some(contents) = Arc::get_mut(&mut record)
        {
            *contents = CellExtras::default();
            self.records.push(record);
        }
    }
    /// An empty, unshared record.
    fn take(&mut self) -> Arc<CellExtras> {
        self.records.pop().unwrap_or_default()
    }
    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.records.len()
    }
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
    /// Whether both give cells the same presentation, comparing side records by value.
    /// Only debug assertions call it.
    #[allow(dead_code)]
    pub(crate) fn same_presentation(&self, other: &Self) -> bool {
        self.packed == other.packed
            && match (&self.extras, &other.extras) {
                (None, None) => true,
                (Some(a), Some(b)) => format!("{a:?}") == format!("{b:?}"),
                _ => false,
            }
    }
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
                combining: Combining::default(),
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
    /// The packed words of a written one- and two-column cell of this presentation and
    /// of a wide cell's spacer, for a template without a side record. The cells they
    /// build with `Cell::from_packed` equal `cell(ch, width, true)` and its `spacer()`.
    #[inline]
    pub(crate) fn plain_words(&self) -> Option<[u32; 3]> {
        let base = self.packed & !(WIDTH_MASK | WRITTEN);
        self.extras.is_none().then_some([
            base | (1 << WIDTH_SHIFT) | WRITTEN,
            base | (2 << WIDTH_SHIFT) | WRITTEN,
            base,
        ])
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

    fn marks(chars: &[char]) -> Combining {
        let mut combining = Combining::default();
        for &ch in chars { combining.push(ch); }
        combining
    }

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
    fn heap_free_ascii_stores_build_the_packed_cells() {
        let styles = [Style::default(), Style { fg: Color::Indexed(9), attrs: 5, bg: Color::Indexed(200), ..Style::default() }];
        let bytes: Vec<u8> = (0u8..0x80).collect();
        for style in styles {
            let template = CellStyle::new(&style, None);
            let packed = template.packed_written_column();
            for len in [0usize, 1, 7, 16, 17, 40, 128] {
                let mut cells = vec![Cell::blank(Color::Indexed(1)); len];
                Cell::store_ascii_heap_free(&mut cells, &bytes[..len], packed);
                for (cell, &byte) in cells.iter().zip(&bytes) {
                    let expected = Cell::from_packed(char::from(byte), packed);
                    assert_eq!(format!("{cell:?}"), format!("{expected:?}"));
                    assert!(*cell == expected);
                }
            }
        }
    }

    #[test]
    fn heap_free_fills_copy_the_cell_exactly() {
        for bg in [Color::Background, Color::Indexed(3), Color::Foreground] {
            let blank = Cell::blank(bg);
            for len in 0..9 {
                let mut cells = vec![Cell::from_packed('x', blank.packed ^ WRITTEN); len];
                Cell::fill_heap_free(&mut cells, &blank);
                assert!(cells.iter().all(|cell| format!("{cell:?}") == format!("{blank:?}") && *cell == blank));
            }
        }
    }

    #[test]
    fn plain_words_build_the_template_cells() {
        let styles = [Style::default(), Style { fg: Color::Indexed(2), attrs: 1, bg: Color::Indexed(4), ..Style::default() },
                      Style { fg: Color::Rgb([1, 2, 3]), underline: 1, ..Style::default() }];
        for style in styles {
            let template = CellStyle::new(&style, None);
            let Some(words) = template.plain_words() else { continue };
            for (width, ch) in [(1u8, 'a'), (2, '中')] {
                let lead = template.cell(ch, width, true);
                let built = Cell::from_packed(ch, words[usize::from(width) - 1]);
                assert_eq!(format!("{built:?}"), format!("{lead:?}"));
                assert_eq!(format!("{:?}", Cell::from_packed(' ', words[2])), format!("{:?}", lead.spacer()));
            }
        }
        let link = Arc::new(Link { id: 1, uri: "https://plain.test".into() });
        assert!(CellStyle::new(&Style::default(), Some(&link)).plain_words().is_none());
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
    fn pooled_records_are_unshared_empty_and_bounded() {
        let link = Arc::new(Link { id: 7, uri: "https://example.invalid".into() });
        let mut pool = RecordPool::default();
        // A record shared with a template stays with its other owner.
        let template = CellStyle::new(&Style::default(), Some(&link));
        let mut shared = template.cell('x', 1, true);
        let before = Arc::strong_count(&link);
        pool.keep(&mut shared);
        assert!(shared.extras.is_none());
        assert_eq!(pool.len(), 0);
        assert_eq!(Arc::strong_count(&link), before, "the template still holds the link");
        // A record the cell alone owns is emptied: its marks go, and so does its link.
        let mut owned = template.cell('e', 1, true);
        drop(template);
        assert!(owned.push_combining('\u{301}'));
        let holders = Arc::strong_count(&link);
        pool.keep(&mut owned);
        assert_eq!(pool.len(), 1);
        assert_eq!(Arc::strong_count(&link), holders - 1, "a pooled record releases its link");
        let mut fresh = Cell::from_packed('a', owned.packed);
        assert!(fresh.push_combining_from('\u{302}', &mut pool));
        assert_eq!(pool.len(), 0);
        assert_eq!(fresh.combining(), &['\u{302}']);
        assert!(fresh.link().is_none());
        assert_eq!(format!("{:?}", fresh.extras), format!("{:?}", Cell::from_packed('a', 0).with_mark('\u{302}').extras));
        // At most `LIMIT` records are kept; the rest are freed.
        for _ in 0..RecordPool::LIMIT + 3 {
            let mut cell = Cell::default();
            assert!(cell.push_combining('\u{301}'));
            pool.keep(&mut cell);
        }
        assert_eq!(pool.len(), RecordPool::LIMIT);
    }

    impl Cell {
        fn with_mark(mut self, mark: char) -> Self {
            assert!(self.push_combining(mark));
            self
        }
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
    fn inline_marks_spill_with_fixed_accounting_and_bounded_clones() {
        let expected: Vec<char> = (0..MAX_COMBINING)
            .map(|offset| char::from_u32(0x300 + offset as u32).unwrap())
            .collect();
        let mut cell = Cell::default();
        assert_eq!(cell.combining_capacity(), 0, "an untouched cell owns no storage");
        for &ch in &expected[..COMBINING_INLINE] { assert!(cell.push_combining(ch)); }
        assert_eq!(cell.combining_capacity(), COMBINING_INLINE);
        assert_eq!(cell.combining(), &expected[..COMBINING_INLINE]);
        assert_eq!(cell.side_bytes(), std::mem::size_of::<CellExtras>());

        let mut spilled = cell.clone();
        assert!(spilled.push_combining(expected[COMBINING_INLINE]));
        assert_eq!(cell.combining_len(), COMBINING_INLINE, "inline detach leaves the original unchanged");
        assert_eq!(spilled.combining_len(), COMBINING_INLINE + 1);
        assert_eq!(spilled.combining_capacity(), MAX_COMBINING);
        let spilled_charge = std::mem::size_of::<CellExtras>()
            + std::mem::size_of::<[char; MAX_COMBINING]>();
        assert_eq!(spilled.side_bytes(), spilled_charge);

        let mut detached = spilled.clone();
        assert!(detached.push_combining(expected[COMBINING_INLINE + 1]));
        assert_eq!(spilled.combining_len(), COMBINING_INLINE + 1, "spilled detach leaves the original unchanged");
        for &ch in &expected[COMBINING_INLINE + 1..] { assert!(spilled.push_combining(ch)); }
        assert_eq!(spilled.combining(), expected);
        assert_eq!(spilled.side_bytes(), spilled_charge);
        assert!(!spilled.push_combining('\u{301}'));
        assert_eq!(spilled.combining_len(), MAX_COMBINING);
        assert_eq!(spilled.side_bytes(), spilled_charge);
    }

    #[test]
    fn equality_ignores_side_record_sharing_but_not_content() {
        let shared = Arc::new(CellExtras {
            combining: marks(&['\u{301}']),
            link: Some(Arc::new(Link { id: 1, uri: "https://a.test".into() })),
            style: None,
        });
        let mut left = Cell::plain('e');
        left.extras = Some(Arc::clone(&shared));
        let mut right = Cell::plain('e');
        right.extras = Some(Arc::new(CellExtras {
            combining: marks(&['\u{301}']),
            link: Some(Arc::new(Link { id: 1, uri: "https://a.test".into() })),
            style: None,
        }));
        assert_eq!(left, right);
        right.push_combining('\u{302}');
        right.set_written(true);
        assert_ne!(left, right);
    }
}
