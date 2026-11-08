//! Portable cell content and presentation. Numeric color indices are protocol data.

use std::sync::Arc;

pub const BOLD: u16 = 1;
pub const ITALIC: u16 = 2;
pub const FAINT: u16 = 4;
pub const INVERSE: u16 = 8;
pub const INVISIBLE: u16 = 16;
pub const STRIKE: u16 = 32;
pub const BLINK: u16 = 64;
pub const MAX_COMBINING: usize = 16;

#[allow(clippy::box_collection)]
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Combining(Option<Box<Vec<char>>>);

impl Combining {
    pub const fn new() -> Self {
        Self(None)
    }
    pub fn push(&mut self, ch: char) {
        self.0.get_or_insert_with(Default::default).push(ch);
    }
    /// Heap bytes owned by this value, for history accounting.
    pub fn heap_bytes(&self) -> usize {
        self.0.as_ref().map_or(0, |v| {
            std::mem::size_of::<Vec<char>>() + v.capacity() * std::mem::size_of::<char>()
        })
    }
}

impl std::ops::Deref for Combining {
    type Target = [char];
    fn deref(&self) -> &[char] {
        self.0.as_deref().map_or(&[], Vec::as_slice)
    }
}

impl<'a> IntoIterator for &'a Combining {
    type Item = &'a char;
    type IntoIter = std::slice::Iter<'a, char>;
    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cell {
    pub ch: char,
    pub combining: Combining,
    /// 0 is the trailing column of a wide character, otherwise 1 or 2.
    pub width: u8,
    pub style: Style,
    pub link: Option<Arc<Link>>,
    pub written: bool,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            ch: ' ',
            combining: Combining::new(),
            width: 1,
            style: Style::default(),
            link: None,
            written: false,
        }
    }
}

impl Cell {
    pub fn blank(bg: Color) -> Self {
        Self {
            style: Style {
                bg,
                ..Style::default()
            },
            ..Self::default()
        }
    }
    pub fn link_id(&self) -> u32 {
        self.link.as_ref().map_or(0, |l| l.id)
    }
    pub fn link_uri(&self) -> Option<&str> {
        self.link.as_deref().map(|l| &*l.uri)
    }
    pub fn text(&self) -> String {
        if self.width == 0 {
            return String::new();
        }
        let mut text = String::from(self.ch);
        text.extend(&self.combining);
        text
    }
    pub fn occupied(&self) -> bool {
        self.ch != ' '
            || !self.combining.is_empty()
            || self.width != 1
            || self.style != Style::default()
            || self.link.is_some()
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
        assert_eq!(std::mem::size_of::<Cell>(), 40);
    }
}
