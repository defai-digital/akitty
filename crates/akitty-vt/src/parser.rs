//! Incremental ECMA-48 framing, independent of screen and host policy.
//!
//! Invalid UTF-8 is replaced, control strings are bounded, and malformed sequences
//! are discarded through their terminator. No incomplete payload is dispatched.

pub const MAX_STRING_BYTES: usize = 1_048_576;
pub const MAX_PARAMETERS: usize = 32;
pub const MAX_SUBPARAMETERS: usize = 16;
const MAX_INTERMEDIATES: usize = 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StringKind {
    Osc,
    Dcs,
    Apc,
    Pm,
    Sos,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Terminator {
    Bell,
    St,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Csi {
    pub prefix: Option<u8>,
    pub params: Vec<Vec<Option<u16>>>,
    pub intermediates: Vec<u8>,
    pub final_byte: u8,
}

impl Csi {
    pub fn value(&self, index: usize, default: u16) -> u16 {
        self.params
            .get(index)
            .and_then(|p| p.first())
            .copied()
            .flatten()
            .unwrap_or(default)
    }
    pub fn count(&self, index: usize) -> usize {
        usize::from(self.value(index, 1).max(1))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Print(char),
    Control(u8),
    Escape {
        intermediates: Vec<u8>,
        final_byte: u8,
    },
    Csi(Csi),
    String {
        kind: StringKind,
        payload: Vec<u8>,
        terminator: Terminator,
    },
}

/// Borrowed text runs stay inside one feed call; the public action stream remains scalar.
pub(crate) enum Input<'a> {
    Ascii(&'a [u8]),
    Csi(&'a mut Csi),
    Action(Action),
}

#[derive(Default, Debug)]
enum State {
    #[default]
    Text,
    Escape,
    Csi,
    String(StringKind),
    StringEscape(StringKind),
}

#[derive(Default)]
pub struct Parser {
    state: State,
    intermediates: Vec<u8>,
    prefix: Option<u8>,
    params: Vec<Vec<Option<u16>>>,
    // A CSI callback borrows parameters. Keep their bounded allocations for the
    // next sequence; owned actions and synchronized queues take that storage.
    param_pool: Vec<Vec<Option<u16>>>,
    payload: Vec<u8>,
    discard: bool,
    utf8: [u8; 4],
    utf8_len: usize,
    utf8_expected: usize,
    string_utf8_remaining: usize,
}

// Retained scratch capacity is not parser state. Keep debug/state comparisons
// focused on the active sequence, including incomplete UTF-8 and discard state.
impl std::fmt::Debug for Parser {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Parser")
            .field("state", &self.state).field("intermediates", &self.intermediates)
            .field("prefix", &self.prefix).field("params", &self.params)
            .field("payload", &self.payload).field("discard", &self.discard)
            .field("utf8", &self.utf8).field("utf8_len", &self.utf8_len)
            .field("utf8_expected", &self.utf8_expected)
            .field("string_utf8_remaining", &self.string_utf8_remaining).finish()
    }
}

impl Parser {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn feed(&mut self, input: &[u8], mut emit: impl FnMut(Action)) {
        self.feed_runs(input, |item| match item {
            Input::Ascii(bytes) => {
                for &byte in bytes { emit(Action::Print(char::from(byte))); }
            }
            Input::Csi(csi) => emit(Action::Csi(std::mem::take(csi))),
            Input::Action(action) => emit(action),
        });
    }

    pub(crate) fn feed_runs(&mut self, input: &[u8], mut emit: impl FnMut(Input<'_>)) {
        let mut index = 0;
        while index < input.len() {
            if matches!(self.state, State::Text) && self.utf8_len == 0 {
                let start = index;
                while index < input.len() && (0x20..=0x7e).contains(&input[index]) {
                    index += 1;
                }
                if index > start { emit(Input::Ascii(&input[start..index])); }
                if index == input.len() {
                    break;
                }
            }
            self.byte(input[index], &mut emit);
            index += 1;
        }
    }

    fn begin(&mut self, state: State) {
        self.state = state;
        self.intermediates.clear();
        for parameter in &mut self.params { parameter.clear(); }
        self.param_pool.append(&mut self.params);
        self.prefix = None;
        self.payload.clear();
        self.discard = false;
        self.string_utf8_remaining = 0;
    }

    fn byte(&mut self, byte: u8, emit: &mut impl FnMut(Input<'_>)) {
        if matches!(self.state, State::Text) && self.utf8_len != 0 {
            if byte & 0xc0 == 0x80 {
                self.utf8[self.utf8_len] = byte;
                self.utf8_len += 1;
                if self.utf8_len == self.utf8_expected {
                    let ch = std::str::from_utf8(&self.utf8[..self.utf8_len])
                        .ok()
                        .and_then(|s| s.chars().next())
                        .unwrap_or('\u{fffd}');
                    self.utf8_len = 0;
                    emit(Input::Action(Action::Print(ch)));
                }
                return;
            }
            self.utf8_len = 0;
            emit(Input::Action(Action::Print('\u{fffd}')));
        }
        if byte == 0x18 || byte == 0x1a {
            self.begin(State::Text);
            return;
        }
        // A UTF-8 continuation byte in a string is data even when its numeric
        // value equals an eight-bit control (for example U+261C ends in 0x9c).
        if matches!(self.state, State::String(_)) {
            if self.string_utf8_remaining != 0 && byte & 0xc0 == 0x80 {
                self.string_utf8_remaining -= 1;
                self.append(byte);
                return;
            }
            self.string_utf8_remaining = match byte {
                0xc2..=0xdf => 1,
                0xe0..=0xef => 2,
                0xf0..=0xf4 => 3,
                _ => 0,
            };
        }
        match self.state {
            State::Text => match byte {
                0x1b => self.begin(State::Escape),
                0x9b => self.begin(State::Csi),
                0x9d => self.begin(State::String(StringKind::Osc)),
                0x90 => self.begin(State::String(StringKind::Dcs)),
                0x9f => self.begin(State::String(StringKind::Apc)),
                0x9e => self.begin(State::String(StringKind::Pm)),
                0x98 => self.begin(State::String(StringKind::Sos)),
                0x00..=0x1f => emit(Input::Action(Action::Control(byte))),
                0x20..=0x7e => emit(Input::Action(Action::Print(char::from(byte)))),
                0x7f..=0x9f => {}
                _ => {
                    self.utf8_expected = match byte {
                        0xc2..=0xdf => 2,
                        0xe0..=0xef => 3,
                        0xf0..=0xf4 => 4,
                        _ => 0,
                    };
                    if self.utf8_expected == 0 {
                        emit(Input::Action(Action::Print('\u{fffd}')));
                    } else {
                        self.utf8[0] = byte;
                        self.utf8_len = 1;
                    }
                }
            },
            State::Escape => match byte {
                0x1b => self.begin(State::Escape),
                0x00..=0x1f => emit(Input::Action(Action::Control(byte))),
                0x20..=0x2f => self.intermediate(byte),
                b'[' if self.intermediates.is_empty() => self.begin(State::Csi),
                b']' if self.intermediates.is_empty() => self.begin(State::String(StringKind::Osc)),
                b'P' if self.intermediates.is_empty() => self.begin(State::String(StringKind::Dcs)),
                b'_' if self.intermediates.is_empty() => self.begin(State::String(StringKind::Apc)),
                b'^' if self.intermediates.is_empty() => self.begin(State::String(StringKind::Pm)),
                b'X' if self.intermediates.is_empty() => self.begin(State::String(StringKind::Sos)),
                0x30..=0x7e => {
                    if !self.discard {
                        emit(Input::Action(Action::Escape {
                            intermediates: std::mem::take(&mut self.intermediates),
                            final_byte: byte,
                        }));
                    }
                    self.begin(State::Text);
                }
                0x7f => {}
                _ => self.discard = true,
            },
            State::Csi => match byte {
                0x1b => self.begin(State::Escape),
                0x00..=0x1f => emit(Input::Action(Action::Control(byte))),
                0x20..=0x2f => self.intermediate(byte),
                b'0'..=b'9' if self.intermediates.is_empty() => {
                    self.ensure_parameter();
                    if !self.discard {
                        let number = self.params.last_mut().unwrap().last_mut().unwrap();
                        *number = Some(
                            number
                                .unwrap_or(0)
                                .saturating_mul(10)
                                .saturating_add(u16::from(byte - b'0')),
                        );
                    }
                }
                b';' if self.intermediates.is_empty() => {
                    self.ensure_parameter();
                    if self.params.len() < MAX_PARAMETERS {
                        self.push_parameter();
                    } else {
                        self.discard = true;
                    }
                }
                b':' if self.intermediates.is_empty() => {
                    self.ensure_parameter();
                    if let Some(param) = self.params.last_mut() {
                        if param.len() < MAX_SUBPARAMETERS {
                            param.push(None);
                        } else {
                            self.discard = true;
                        }
                    }
                }
                0x3c..=0x3f
                    if self.params.is_empty()
                        && self.intermediates.is_empty()
                        && self.prefix.is_none() =>
                {
                    self.prefix = Some(byte)
                }
                0x40..=0x7e => {
                    if !self.discard {
                        let mut csi = Csi {
                            prefix: self.prefix,
                            params: std::mem::take(&mut self.params),
                            intermediates: std::mem::take(&mut self.intermediates),
                            final_byte: byte,
                        };
                        emit(Input::Csi(&mut csi));
                        self.params = csi.params;
                        self.intermediates = csi.intermediates;
                    }
                    self.begin(State::Text);
                }
                0x7f => {}
                _ => self.discard = true,
            },
            State::String(kind) => match byte {
                0x1b => self.state = State::StringEscape(kind),
                0x9c => self.finish_string(kind, Terminator::St, emit),
                0x07 if kind == StringKind::Osc => self.finish_string(kind, Terminator::Bell, emit),
                0x00..=0x1f | 0x7f if kind == StringKind::Osc => {}
                _ => self.append(byte),
            },
            State::StringEscape(kind) => {
                if byte == b'\\' || byte == 0x9c {
                    self.finish_string(kind, Terminator::St, emit);
                } else if byte == 0x7f || byte < 0x20 && byte != 0x1b { /* Controls do not abandon a pending ST. */
                } else {
                    self.begin(State::Escape);
                    if byte != 0x1b {
                        self.byte(byte, emit);
                    }
                }
            }
        }
    }

    fn intermediate(&mut self, byte: u8) {
        if self.intermediates.len() < MAX_INTERMEDIATES {
            self.intermediates.push(byte);
        } else {
            self.discard = true;
        }
    }
    fn ensure_parameter(&mut self) {
        if self.params.is_empty() {
            self.push_parameter();
        }
    }
    fn push_parameter(&mut self) {
        let mut parameter = self.param_pool.pop().unwrap_or_default();
        parameter.clear();
        parameter.push(None);
        self.params.push(parameter);
    }
    fn append(&mut self, byte: u8) {
        if !self.discard {
            if self.payload.len() < MAX_STRING_BYTES {
                self.payload.push(byte);
            } else {
                self.payload.clear();
                self.discard = true;
            }
        }
    }
    fn finish_string(
        &mut self,
        kind: StringKind,
        terminator: Terminator,
        emit: &mut impl FnMut(Input<'_>),
    ) {
        if !self.discard {
            emit(Input::Action(Action::String {
                kind,
                payload: std::mem::take(&mut self.payload),
                terminator,
            }));
        }
        self.begin(State::Text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn parse(parts: &[&[u8]]) -> Vec<Action> {
        let mut parser = Parser::default();
        let mut actions = Vec::new();
        for bytes in parts {
            parser.feed(bytes, |a| actions.push(a));
        }
        actions
    }

    #[test]
    fn every_chunk_boundary_preserves_actions() {
        let bytes =
            "hi中😀e\u{301}\x1b[?25l\x1b[38:2::1:2:3m\x1b]2;中文☜\x1b\\\x1b_Ga=q;AAAA\x1b\\"
                .as_bytes();
        let expected = parse(&[bytes]);
        for cut in 0..=bytes.len() {
            assert_eq!(
                parse(&[&bytes[..cut], &bytes[cut..]]),
                expected,
                "cut {cut}"
            );
        }
        let singles: Vec<_> = bytes.chunks(1).collect();
        assert_eq!(parse(&singles), expected);
        assert!(expected.iter().any(
            |a| matches!(a, Action::String { payload, .. } if payload == "2;中文☜".as_bytes())
        ));
    }

    #[test]
    fn malformed_utf8_recovers_without_eating_controls() {
        assert_eq!(
            parse(&[b"\xe4\x1b[6nZ"]),
            vec![
                Action::Print('\u{fffd}'),
                Action::Csi(Csi {
                    prefix: None,
                    params: vec![vec![Some(6)]],
                    intermediates: vec![],
                    final_byte: b'n'
                }),
                Action::Print('Z')
            ]
        );
        assert_eq!(
            parse(&[b"\xf0\x80\x80\x80"]),
            vec![Action::Print('\u{fffd}')]
        );
    }

    #[test]
    fn cancelled_strings_and_escapes_do_not_leak_payload() {
        assert_eq!(
            parse(&[b"\x1b]2;secret\x18ok"]),
            vec![Action::Print('o'), Action::Print('k')]
        );
        assert_eq!(
            parse(&[b"\x1b[12\x07;3H"]),
            vec![
                Action::Control(7),
                Action::Csi(Csi {
                    prefix: None,
                    params: vec![vec![Some(12)], vec![Some(3)]],
                    intermediates: vec![],
                    final_byte: b'H'
                })
            ]
        );
        assert_eq!(parse(&[b"\x1b]2;old\x1b[6n"]), parse(&[b"\x1b[6n"]));
    }

    #[test]
    fn borrowed_csi_and_owned_actions_agree_across_reuse_overflow_and_cancellation() {
        let maximal = format!("\x1b[{}m", (0..MAX_PARAMETERS).map(|_| {
            (0..MAX_SUBPARAMETERS).map(|n| n.to_string()).collect::<Vec<_>>().join(":")
        }).collect::<Vec<_>>().join(";"));
        let bytes = format!("{maximal}\x1b[1m\x1b[m\x1b[38:2::1:2:3m\x1b[12\x18\x1b[6n\x1b[{}mOK",
                            "1;".repeat(MAX_PARAMETERS + 1));
        let expected = parse(&[bytes.as_bytes()]);
        for size in [1, 3, 8192] {
            let mut parser = Parser::default();
            for _ in 0..3 {
                let mut actual = Vec::new();
                for chunk in bytes.as_bytes().chunks(size) {
                    parser.feed_runs(chunk, |input| match input {
                        Input::Ascii(bytes) => actual.extend(bytes.iter().map(|&b| Action::Print(char::from(b)))),
                        Input::Csi(csi) => actual.push(Action::Csi(csi.clone())),
                        Input::Action(action) => actual.push(action),
                    });
                }
                assert_eq!(actual, expected);
                assert!(parser.params.len() + parser.param_pool.len() <= MAX_PARAMETERS);
                assert!(parser.param_pool.iter().all(|p| p.is_empty() && p.capacity() >= MAX_SUBPARAMETERS));
            }
        }
    }

    #[test]
    fn resources_stay_bounded_and_overflow_is_not_dispatched() {
        let mut bytes = b"\x1b]2;".to_vec();
        bytes.resize(MAX_STRING_BYTES + 100, b'x');
        bytes.extend_from_slice(b"\x1b\\ok");
        assert_eq!(
            parse(&[&bytes]),
            vec![Action::Print('o'), Action::Print('k')]
        );
        let csi = format!("\x1b[{}mZ", "1;".repeat(1000));
        assert_eq!(parse(&[csi.as_bytes()]), vec![Action::Print('Z')]);
        let actions = parse(&[b"\x1b[999999999999A"]);
        assert!(matches!(&actions[0], Action::Csi(c) if c.value(0, 0) == u16::MAX));
    }
}
