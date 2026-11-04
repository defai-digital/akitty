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

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Color {
    #[default]
    Foreground,
    Background,
    Indexed(u8),
    Rgb(u32),
}

impl Color {
    pub fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self::Rgb(u32::from(r) << 16 | u32::from(g) << 8 | u32::from(b))
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cell {
    pub ch: char,
    pub combining: Vec<char>,
    /// 0 is the trailing column of a wide character, otherwise 1 or 2.
    pub width: u8,
    pub style: Style,
    pub link: Option<Arc<str>>,
    pub link_id: u32,
    pub written: bool,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            ch: ' ',
            combining: Vec::new(),
            width: 1,
            style: Style::default(),
            link: None,
            link_id: 0,
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
            Color::Rgb(rgb) => rgb,
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
