//! Platform-neutral terminal keyboard encoding. Functional key identities and
//! modifier bits follow the published Kitty keyboard protocol. Hosts translate
//! native/DOM events and retain responsibility for IME and application shortcuts.

pub const SHIFT: u8 = 1;
pub const ALT: u8 = 2;
pub const CTRL: u8 = 4;
pub const SUPER: u8 = 8;

// Stable AkiTTY identities for keys whose wire representation predates CSI-u.
pub const INSERT: u32 = 57348;
pub const DELETE: u32 = 57349;
pub const LEFT: u32 = 57350;
pub const RIGHT: u32 = 57351;
pub const UP: u32 = 57352;
pub const DOWN: u32 = 57353;
pub const PAGE_UP: u32 = 57354;
pub const PAGE_DOWN: u32 = 57355;
pub const HOME: u32 = 57356;
pub const END: u32 = 57357;
pub const F1: u32 = 57364;

#[derive(Clone, Copy, Debug, Default)]
pub struct Options {
    pub app_cursor: bool,
    pub app_keypad: bool,
    pub alt_escape: bool,
    pub modify_other_keys: u8,
    pub kitty_flags: u8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Press,
    Repeat,
    Release,
}

#[derive(Clone, Debug)]
pub struct Key<'a> {
    pub code: u32,
    pub shifted: Option<u32>,
    pub base_layout: Option<u32>,
    pub modifiers: u8,
    pub action: Action,
    pub text: &'a str,
    pub composing: bool,
}

impl<'a> Key<'a> {
    pub fn press(code: u32, modifiers: u8, text: &'a str) -> Self {
        Self {
            code,
            shifted: None,
            base_layout: None,
            modifiers,
            action: Action::Press,
            text,
            composing: false,
        }
    }
}

pub fn encode(key: &Key<'_>, options: Options) -> Vec<u8> {
    if key.composing || key.text.len() > 4096 {
        return Vec::new();
    }
    let flags = options.kitty_flags & 31;
    let report_events = flags & 2 != 0;
    if key.action == Action::Release && !report_events {
        return Vec::new();
    }
    let mods = key.modifiers & 0x3f;
    let code = if flags & 8 == 0 {
        keypad_legacy_code(key.code).unwrap_or(key.code)
    } else {
        key.code
    };
    let kitty =
        flags & 8 != 0 || flags & 1 != 0 && (code == 27 || mods & !SHIFT != 0 || code >= 57344);
    let editing = matches!(key.code, 9 | 13 | 127 | 57414);
    if key.action == Action::Release && editing && flags & 8 == 0 {
        return Vec::new();
    }
    let text_key = (32..57344).contains(&code) && code != 127;
    let modifier = u16::from(if flags & 8 != 0 || !text_key && flags & 3 != 0 {
        key.modifiers
    } else {
        mods
    }) + 1;
    let event = if report_events && (!editing || flags & 8 != 0) {
        match key.action {
            Action::Press => "",
            Action::Repeat => ":2",
            Action::Release => ":3",
        }
    } else {
        ""
    };
    if let Some((number, final_byte, ss3)) = function(key.code) {
        if kitty
            || mods != 0
            || report_events && (key.action != Action::Press || key.modifiers != 0)
        {
            if flags & 11 != 0 && key.code == F1 + 2 {
                return format!("\x1b[13;{modifier}{event}~").into_bytes();
            }
            return format!("\x1b[{number};{modifier}{event}{final_byte}").into_bytes();
        }
        if let Some(final_byte) = ss3 {
            let application = options.app_cursor
                && matches!(key.code, LEFT | RIGHT | UP | DOWN | HOME | END)
                || (F1..=57367).contains(&key.code);
            return format!("\x1b{}{final_byte}", if application { "O" } else { "[" }).into_bytes();
        }
        return format!("\x1b[{number}{final_byte}").into_bytes();
    }
    if !kitty && key.action == Action::Release {
        return Vec::new();
    }
    if kitty {
        let mut identity = code.to_string();
        if flags & 4 != 0 {
            if let Some(shifted) = key.shifted.filter(|n| *n != key.code) {
                identity.push_str(&format!(":{shifted}"));
            } else if key.base_layout.is_some_and(|n| n != key.code) {
                identity.push(':');
            }
            if let Some(base) = key.base_layout.filter(|n| *n != key.code) {
                identity.push_str(&format!(":{base}"));
            }
        }
        let associated = if flags & 16 != 0
            && key.action != Action::Release
            && !key.text.is_empty()
            && key.modifiers & (CTRL | SUPER) == 0
        {
            format!(
                ";{}",
                key.text
                    .chars()
                    .filter(|ch| !ch.is_control())
                    .map(|ch| u32::from(ch).to_string())
                    .collect::<Vec<_>>()
                    .join(":")
            )
        } else {
            String::new()
        };
        return format!("\x1b[{identity};{modifier}{event}{associated}u").into_bytes();
    }
    if key.code == 9 && mods == SHIFT {
        return b"\x1b[Z".to_vec();
    }
    // xterm's level 2 leaves Shift+printable text alone; only Space and Return are claimed.
    let shifted_text = mods == SHIFT && !key.text.is_empty() && key.text != " " && key.code != 13
        && key.text.chars().all(|ch| !ch.is_control());
    if options.modify_other_keys == 2 && mods != 0 && !shifted_text && key.code < 57344 {
        return format!("\x1b[27;{modifier};{}~", key.code).into_bytes();
    }
    let keypad = if options.app_keypad {
        keypad_application(key.code)
    } else {
        None
    };
    let mut output = if let Some(code) = keypad {
        format!("\x1bO{code}").into_bytes()
    } else if mods & CTRL != 0 {
        let scalar = key.text.chars().next().map(u32::from).unwrap_or(key.code);
        let control = match scalar {
            32 | 64 | 50 => Some(0),
            65..=90 => Some(scalar as u8 - 64),
            97..=122 => Some(scalar as u8 - 96),
            91..=95 => Some(scalar as u8 - 64),
            51 => Some(27),
            52 => Some(28),
            53 => Some(29),
            54 => Some(30),
            55 => Some(31),
            47 => Some(31),
            56 | 63 => Some(127),
            126 => Some(30),
            _ => None,
        };
        control.map_or_else(|| legacy_text(key), |byte| vec![byte])
    } else {
        legacy_text(key)
    };
    if options.alt_escape && mods & ALT != 0 && key.text.is_ascii() && !output.is_empty() {
        output.insert(0, 27);
    }
    output
}

fn legacy_text(key: &Key<'_>) -> Vec<u8> {
    if !key.text.is_empty() {
        return key.text.as_bytes().to_vec();
    }
    match key.code {
        9 => vec![9],
        13 => vec![13],
        27 => vec![27],
        127 => vec![127],
        code @ 57399..=57416 => vec![keypad_legacy_code(code).unwrap() as u8],
        _ => Vec::new(),
    }
}

fn keypad_legacy_code(code: u32) -> Option<u32> {
    Some(match code {
        57399..=57408 => u32::from(b'0') + code - 57399,
        57409 => u32::from(b'.'),
        57410 => u32::from(b'/'),
        57411 => u32::from(b'*'),
        57412 => u32::from(b'-'),
        57413 => u32::from(b'+'),
        57414 => 13,
        57415 => u32::from(b'='),
        57416 => u32::from(b','),
        _ => return None,
    })
}

fn function(code: u32) -> Option<(u16, char, Option<char>)> {
    Some(match code {
        UP => (1, 'A', Some('A')),
        DOWN => (1, 'B', Some('B')),
        RIGHT => (1, 'C', Some('C')),
        LEFT => (1, 'D', Some('D')),
        HOME => (1, 'H', Some('H')),
        END => (1, 'F', Some('F')),
        INSERT => (2, '~', None),
        DELETE => (3, '~', None),
        PAGE_UP => (5, '~', None),
        PAGE_DOWN => (6, '~', None),
        57364 => (1, 'P', Some('P')),
        57365 => (1, 'Q', Some('Q')),
        57366 => (1, 'R', Some('R')),
        57367 => (1, 'S', Some('S')),
        57368 => (15, '~', None),
        57369 => (17, '~', None),
        57370 => (18, '~', None),
        57371 => (19, '~', None),
        57372 => (20, '~', None),
        57373 => (21, '~', None),
        57374 => (23, '~', None),
        57375 => (24, '~', None),
        _ => return None,
    })
}
fn keypad_application(code: u32) -> Option<char> {
    match code {
        57399..=57408 => char::from_u32(u32::from(b'p') + code - 57399),
        57409 => Some('n'),
        57410 => Some('o'),
        57411 => Some('j'),
        57412 => Some('m'),
        57413 => Some('k'),
        57414 => Some('M'),
        57415 => Some('X'),
        57416 => Some('l'),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn text(key: Key<'_>, options: Options) -> String {
        String::from_utf8(encode(&key, options)).unwrap()
    }
    #[test]
    fn event_types_report_function_releases_without_disambiguation() {
        for (action, expected) in [
            (Action::Repeat, "\x1b[1;1:2D"),
            (Action::Release, "\x1b[1;1:3D"),
        ] {
            let mut key = Key::press(LEFT, 0, "");
            key.action = action;
            assert_eq!(
                text(
                    key,
                    Options {
                        kitty_flags: 2,
                        ..Options::default()
                    }
                ),
                expected
            );
        }
        assert_eq!(
            text(
                Key::press(LEFT, 64, ""),
                Options {
                    kitty_flags: 2,
                    ..Options::default()
                }
            ),
            "\x1b[1;65D"
        );
    }

    #[test]
    fn alternate_key_reporting_does_not_claim_shift_only_keys_and_f3_is_unambiguous() {
        let options = Options {
            kitty_flags: 4,
            ..Options::default()
        };
        assert_eq!(text(Key::press(9, SHIFT, ""), options), "\x1b[Z");
        assert_eq!(text(Key::press(97, SHIFT, "A"), options), "A");
        assert_eq!(
            text(
                Key::press(F1 + 2, CTRL, ""),
                Options {
                    kitty_flags: 1,
                    ..options
                }
            ),
            "\x1b[13;5~"
        );
    }

    #[test]
    fn text_lock_modifiers_and_editing_release_follow_progressive_flags() {
        assert_eq!(
            text(
                Key::press(99, CTRL | 64, "c"),
                Options {
                    kitty_flags: 1,
                    ..Options::default()
                }
            ),
            "\x1b[99;5u"
        );
        assert_eq!(
            text(
                Key::press(99, CTRL | 64, "c"),
                Options {
                    kitty_flags: 8,
                    ..Options::default()
                }
            ),
            "\x1b[99;69u"
        );
        for code in [9, 13, 127, 57414] {
            let mut key = Key::press(code, SHIFT, "");
            key.action = Action::Release;
            assert!(
                encode(
                    &key,
                    Options {
                        kitty_flags: 3,
                        ..Options::default()
                    }
                )
                .is_empty()
            );
        }
    }

    #[test]
    fn keypad_uses_legacy_text_until_report_all_claims_its_physical_identity() {
        let options = Options {
            kitty_flags: 1,
            ..Options::default()
        };
        assert_eq!(text(Key::press(57414, 0, ""), options), "\r");
        assert_eq!(text(Key::press(57400, 0, "1"), options), "1");
        assert_eq!(text(Key::press(57414, CTRL, ""), options), "\x1b[13;5u");
        assert_eq!(
            text(
                Key::press(57400, 0, "1"),
                Options {
                    app_keypad: true,
                    ..options
                }
            ),
            "\x1bOq"
        );
        assert_eq!(
            text(
                Key::press(57400, 0, "1"),
                Options {
                    kitty_flags: 8,
                    ..options
                }
            ),
            "\x1b[57400;1u"
        );
    }

    #[test]
    fn legacy_controls_modifiers_and_application_modes() {
        let options = Options {
            alt_escape: true,
            ..Options::default()
        };
        assert_eq!(encode(&Key::press(99, CTRL, "c"), options), [3]);
        assert_eq!(text(Key::press(120, ALT | SHIFT, "X"), options), "\x1bX");
        assert_eq!(text(Key::press(UP, 0, ""), options), "\x1b[A");
        assert_eq!(
            text(
                Key::press(UP, 0, ""),
                Options {
                    app_cursor: true,
                    ..options
                }
            ),
            "\x1bOA"
        );
        assert_eq!(text(Key::press(UP, CTRL, ""), options), "\x1b[1;5A");
        assert_eq!(text(Key::press(DELETE, SHIFT, ""), options), "\x1b[3;2~");
        assert_eq!(encode(&Key::press(47, CTRL, "/"), options), [31]);
        assert_eq!(encode(&Key::press(96, CTRL | SHIFT, "~"), options), [30]);
        let other = Options { modify_other_keys: 2, ..options };
        assert_eq!(text(Key::press(97, SHIFT, "A"), other), "A");
        assert_eq!(text(Key::press(97, CTRL, "a"), other), "\x1b[27;5;97~");
        assert_eq!(text(Key::press(32, SHIFT, " "), other), "\x1b[27;2;32~");
        assert_eq!(text(Key::press(9, SHIFT, ""), options), "\x1b[Z");
        assert_eq!(
            text(
                Key::press(57400, 0, ""),
                Options {
                    app_keypad: true,
                    ..options
                }
            ),
            "\x1bOq"
        );
    }
    #[test]
    fn legacy_control_modifiers_do_not_swallow_editing_or_keypad_keys() {
        for (code, expected) in [(9, 9), (13, 13), (27, 27), (127, 127), (57414, 13)] {
            assert_eq!(
                encode(&Key::press(code, CTRL, ""), Options::default()),
                [expected]
            );
        }
        assert_eq!(
            encode(
                &Key::press(13, CTRL | ALT, ""),
                Options {
                    alt_escape: true,
                    ..Options::default()
                }
            ),
            [27, 13]
        );
    }

    #[test]
    fn kitty_flags_control_ambiguity_text_alternates_and_release() {
        let options = Options {
            kitty_flags: 1,
            ..Options::default()
        };
        assert_eq!(text(Key::press(99, CTRL, "c"), options), "\x1b[99;5u");
        assert_eq!(text(Key::press(97, SHIFT, "A"), options), "A");
        assert_eq!(text(Key::press(13, 0, ""), options), "\r");
        let mut key = Key::press(97, SHIFT | ALT, "A");
        key.shifted = Some(65);
        key.base_layout = Some(113);
        key.action = Action::Repeat;
        assert_eq!(
            text(
                key.clone(),
                Options {
                    kitty_flags: 31,
                    ..options
                }
            ),
            "\x1b[97:65:113;4:2;65u"
        );
        key.action = Action::Release;
        assert_eq!(
            text(
                key.clone(),
                Options {
                    kitty_flags: 31,
                    ..options
                }
            ),
            "\x1b[97:65:113;4:3u"
        );
        assert!(encode(&key, options).is_empty());
        key.composing = true;
        assert!(
            encode(
                &key,
                Options {
                    kitty_flags: 31,
                    ..options
                }
            )
            .is_empty()
        );
    }
}
