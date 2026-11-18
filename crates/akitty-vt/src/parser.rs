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
    /// A run of printable text: ASCII `0x20..=0x7e` plus complete scalars from valid
    /// UTF-8. It never holds a control byte or a sequence introducer, and it is valid
    /// UTF-8 by construction (see the safety note where the run is scanned), so a host
    /// receives it as `&str` and never revalidates it. The flag says the run is all
    /// ASCII, which the scan learns for free.
    Text(&'a str, bool),
    Csi(&'a mut Csi),
    /// A C0 control from the text fast path, the same as `Action(Action::Control(_))`
    /// but owning nothing, so dispatching it needs no drop check.
    Control(u8),
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

/// The end of the run scan from `index`, just after a run's first multi-byte scalar:
/// whole chunks first (`text_chunks`), then printable ASCII bytes, ASCII words after
/// each multi-byte scalar and complete scalars, up to the first other byte. Kept out
/// of line so the ASCII scan stays small.
#[inline(never)]
fn mixed_text_end(input: &[u8], mut index: usize) -> usize {
    index += text_chunks(&input[index..]);
    index += whole_printable_words(&input[index..]);
    while index < input.len() {
        if (0x20..=0x7e).contains(&input[index]) {
            index += 1;
            continue;
        }
        match scalar_width(input, index) {
            Some(width) => {
                index += width;
                index += whole_printable_words(&input[index..]);
            }
            None => break,
        }
    }
    index
}

/// The length of a prefix of `input` (which starts at a character boundary) that the
/// run scan would take whole: printable ASCII and complete valid multi-byte scalars,
/// with no C0 control, DEL or invalid byte. Takes whole sixteen-byte chunks, then backs
/// off a trailing incomplete sequence, so it may stop short of the scan's end (the scan
/// continues from there) but never past it.
#[inline(never)]
fn text_chunks(input: &[u8]) -> usize {
    let mut taken = chunks::valid_chunks(input);
    // Every taken chunk was valid given the bytes before it, so only a sequence that
    // starts in the last three bytes can be cut short by the end of the prefix.
    for back in 1..=3.min(taken) {
        let byte = input[taken - back];
        if byte >= 0xc0 {
            let length = match byte {
                0xc0..=0xdf => 2,
                0xe0..=0xef => 3,
                _ => 4,
            };
            if length > back {
                taken -= back;
            }
            break;
        }
    }
    taken
}

#[cfg(target_arch = "aarch64")]
mod chunks {
    use std::arch::aarch64::*;

    const TOO_SHORT: u8 = 1 << 0;
    const TOO_LONG: u8 = 1 << 1;
    const OVERLONG_3: u8 = 1 << 2;
    const TOO_LARGE: u8 = 1 << 3;
    const SURROGATE: u8 = 1 << 4;
    const OVERLONG_2: u8 = 1 << 5;
    const TOO_LARGE_1000: u8 = 1 << 6;
    const OVERLONG_4: u8 = 1 << 6;
    const TWO_CONTS: u8 = 1 << 7;
    const CARRY: u8 = TOO_SHORT | TOO_LONG | TWO_CONTS;

    const INCOMPLETE_ABOVE: [u8; 16] =
        [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xef, 0xdf, 0xbf];

    /// Error classes by the previous byte's high nibble.
    const FIRST_HIGH: [u8; 16] = [
        TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG,
        TWO_CONTS, TWO_CONTS, TWO_CONTS, TWO_CONTS,
        TOO_SHORT | OVERLONG_2,
        TOO_SHORT,
        TOO_SHORT | OVERLONG_3 | SURROGATE,
        TOO_SHORT | TOO_LARGE | TOO_LARGE_1000 | OVERLONG_4,
    ];
    /// Error classes by the previous byte's low nibble.
    const FIRST_LOW: [u8; 16] = [
        CARRY | OVERLONG_3 | OVERLONG_2 | OVERLONG_4,
        CARRY | OVERLONG_2,
        CARRY,
        CARRY,
        CARRY | TOO_LARGE,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
        CARRY | TOO_LARGE | TOO_LARGE_1000 | SURROGATE,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
        CARRY | TOO_LARGE | TOO_LARGE_1000,
    ];
    /// Error classes by the current byte's high nibble.
    const SECOND_HIGH: [u8; 16] = [
        TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT,
        TOO_LONG | OVERLONG_2 | TWO_CONTS | OVERLONG_3 | TOO_LARGE_1000 | OVERLONG_4,
        TOO_LONG | OVERLONG_2 | TWO_CONTS | OVERLONG_3 | TOO_LARGE,
        TOO_LONG | OVERLONG_2 | TWO_CONTS | SURROGATE | TOO_LARGE,
        TOO_LONG | OVERLONG_2 | TWO_CONTS | SURROGATE | TOO_LARGE,
        TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT,
    ];

    /// The length of the leading whole sixteen-byte chunks of `input` that hold no C0
    /// control or DEL and are valid UTF-8 given the chunks before them (the input
    /// starts at a character boundary). A sequence may run on past the last chunk.
    /// This is the lookup-table validation of Keiser and Lemire, "Validating UTF-8 In
    /// Less Than One Instruction Per Byte" (2021): each byte's error classes from the
    /// byte before it and its own high nibble must match the continuation bytes that
    /// three- and four-byte leads two and three bytes back require.
    pub(super) fn valid_chunks(input: &[u8]) -> usize {
        // SAFETY: NEON is part of the aarch64 baseline; every load reads sixteen bytes
        // inside `input`.
        unsafe {
            let first_high = vld1q_u8(FIRST_HIGH.as_ptr());
            let first_low = vld1q_u8(FIRST_LOW.as_ptr());
            let second_high = vld1q_u8(SECOND_HIGH.as_ptr());
            // A lead byte in the last three positions at or above these needs
            // continuation bytes in the next chunk.
            let incomplete_above = vld1q_u8(INCOMPLETE_ABOVE.as_ptr());
            let mut previous = vdupq_n_u8(0);
            let mut taken = 0;
            while let Some(chunk) = input[taken..].first_chunk::<16>() {
                let bytes = vld1q_u8(chunk.as_ptr());
                let control = vorrq_u8(vcltq_u8(bytes, vdupq_n_u8(0x20)), vceqq_u8(bytes, vdupq_n_u8(0x7f)));
                if vmaxvq_u8(bytes) < 0x80 {
                    // An ASCII chunk is valid unless the chunk before ended inside a
                    // sequence.
                    if vmaxvq_u8(vorrq_u8(control, vqsubq_u8(previous, incomplete_above))) != 0 {
                        break;
                    }
                    previous = bytes;
                    taken += 16;
                    continue;
                }
                let prev1 = vextq_u8::<15>(previous, bytes);
                let special = vandq_u8(
                    vandq_u8(
                        vqtbl1q_u8(first_high, vshrq_n_u8::<4>(prev1)),
                        vqtbl1q_u8(first_low, vandq_u8(prev1, vdupq_n_u8(0x0f))),
                    ),
                    vqtbl1q_u8(second_high, vshrq_n_u8::<4>(bytes)),
                );
                let prev2 = vextq_u8::<14>(previous, bytes);
                let prev3 = vextq_u8::<13>(previous, bytes);
                let third = vqsubq_u8(prev2, vdupq_n_u8(0xe0 - 0x80));
                let fourth = vqsubq_u8(prev3, vdupq_n_u8(0xf0 - 0x80));
                let required = vandq_u8(vorrq_u8(third, fourth), vdupq_n_u8(0x80));
                let error = vorrq_u8(veorq_u8(required, special), control);
                if vmaxvq_u8(error) != 0 {
                    break;
                }
                previous = bytes;
                taken += 16;
            }
            taken
        }
    }
}

#[cfg(not(target_arch = "aarch64"))]
mod chunks {
    pub(super) fn valid_chunks(_input: &[u8]) -> usize {
        0
    }
}

/// Byte width of a complete printable multi-byte scalar at `index`, or `None` when the
/// byte needs the state machine: a control, a sequence introducer, or invalid UTF-8.
#[inline]
fn scalar_width(input: &[u8], index: usize) -> Option<usize> {
    let byte = input[index];
    if byte < 0x80 {
        return None;
    }
    let width = match byte {
        0xc2..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf4 => 4,
        _ => return None,
    };
    let sequence = input.get(index..index + width)?;
    let continuation = |byte| byte & 0xc0 == 0x80;
    let valid = match width {
        2 => continuation(sequence[1]),
        3 => {
            continuation(sequence[2])
                && match byte {
                    0xe0 => (0xa0..=0xbf).contains(&sequence[1]),
                    0xed => (0x80..=0x9f).contains(&sequence[1]),
                    _ => continuation(sequence[1]),
                }
        }
        4 => {
            continuation(sequence[2])
                && continuation(sequence[3])
                && match byte {
                    0xf0 => (0x90..=0xbf).contains(&sequence[1]),
                    0xf4 => (0x80..=0x8f).contains(&sequence[1]),
                    _ => continuation(sequence[1]),
                }
        }
        _ => false,
    };
    valid.then_some(width)
}

impl Parser {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn feed(&mut self, input: &[u8], mut emit: impl FnMut(Action)) {
        self.feed_runs(input, |item| match item {
            Input::Text(text, _) => {
                for ch in text.chars() { emit(Action::Print(ch)); }
            }
            Input::Csi(csi) => emit(Action::Csi(std::mem::take(csi))),
            Input::Control(byte) => emit(Action::Control(byte)),
            Input::Action(action) => emit(action),
        });
    }

    pub(crate) fn feed_runs(&mut self, input: &[u8], mut emit: impl FnMut(Input<'_>)) {
        let mut index = 0;
        while index < input.len() {
            if matches!(self.state, State::Text) && self.utf8_len == 0 {
                let start = index;
                let mut ascii = true;
                // Printable ASCII is skipped a word at a time where a run opens and
                // after each multi-byte scalar, up to the exact first other byte. The
                // byte loop takes a short tail and the rest, and a complete multi-byte scalar
                // extends the same run so hosts decode it once.
                index += printable_words(&input[index..]);
                while index < input.len() {
                    if (0x20..=0x7e).contains(&input[index]) {
                        index += 1;
                        continue;
                    }
                    match scalar_width(input, index) {
                        Some(width) => {
                            ascii = false;
                            index = mixed_text_end(input, index + width);
                            break;
                        }
                        None => break,
                    }
                }
                if index > start {
                    // SAFETY: every byte in `start..index` was accepted either as
                    // printable ASCII or as a complete scalar sequence that
                    // `scalar_width` validated for that exact slice, and the scan
                    // only advances by whole ASCII bytes or whole scalars. The range is
                    // therefore a concatenation of valid UTF-8 sequences. Malformed
                    // input never reaches this point: the scan stops and the byte state
                    // machine consumes it instead.
                    let text = unsafe { std::str::from_utf8_unchecked(&input[start..index]) };
                    emit(Input::Text(text, ascii));
                }
                if index == input.len() {
                    break;
                }
                // A C0 control other than the cancels and ESC is the byte machine's
                // Text-state control action; skip its general dispatch.
                if input[index] < 0x20 && !matches!(input[index], 0x18 | 0x1a | 0x1b) {
                    emit(Input::Control(input[index]));
                    index += 1;
                    continue;
                }
                // ESC [ with the whole introducer in this chunk: the byte machine would
                // begin a CSI; collect its ordinary body here instead.
                if input[index] == 0x1b && input.get(index + 1) == Some(&b'[') {
                    self.begin_from_text(State::Csi);
                    index = self.csi_body(input, index + 2, &mut emit);
                    continue;
                }
            }
            self.byte(input[index], &mut emit);
            index += 1;
        }
    }

    /// Collect a CSI body from `input[index..]` in the state the byte machine has right
    /// after its introducer. Handles the bytes that sequence almost always holds (a
    /// leading prefix, digits, `;` and the final byte) with the parameter's digits kept
    /// in a local, and applies exactly the byte machine's transitions for them. Any
    /// other byte, a parameter beyond the limit or the end of the chunk stops here with
    /// the parser state the byte machine would have, and returns the index of the first
    /// byte it has not consumed.
    fn csi_body(&mut self, input: &[u8], mut index: usize, emit: &mut impl FnMut(Input<'_>)) -> usize {
        if let Some(&prefix @ 0x3c..=0x3f) = input.get(index) {
            self.prefix = Some(prefix);
            index += 1;
        }
        // The value of the last parameter's (only) subparameter, while it has one.
        let mut value: Option<u16> = None;
        while let Some(&byte) = input.get(index) {
            match byte {
                b'0'..=b'9' => {
                    if self.params.is_empty() {
                        self.push_parameter();
                    }
                    value = Some(value.unwrap_or(0).saturating_mul(10).saturating_add(u16::from(byte - b'0')));
                }
                // At the limit the byte machine discards the sequence; it takes this `;`.
                b';' if self.params.len() < MAX_PARAMETERS => {
                    if let Some(last) = self.params.last_mut() {
                        last[0] = value;
                    } else {
                        self.push_parameter();
                    }
                    self.push_parameter();
                    value = None;
                }
                0x40..=0x7e => {
                    if let Some(last) = self.params.last_mut() {
                        last[0] = value;
                    }
                    let mut csi = Csi {
                        prefix: self.prefix,
                        params: std::mem::take(&mut self.params),
                        intermediates: std::mem::take(&mut self.intermediates),
                        final_byte: byte,
                    };
                    emit(Input::Csi(&mut csi));
                    self.params = csi.params;
                    self.intermediates = csi.intermediates;
                    self.begin(State::Text);
                    return index + 1;
                }
                _ => break,
            }
            index += 1;
        }
        if let Some(last) = self.params.last_mut() {
            last[0] = value;
        }
        index
    }

    /// Clear the UTF-8 scratch bytes, which outlive the sequence that used them.
    #[cfg(test)]
    pub(crate) fn clear_scratch_for_test(&mut self) {
        let pending = self.utf8_len;
        self.utf8[pending..].fill(0);
        if pending == 0 {
            self.utf8_expected = 0;
        }
    }
    /// `begin` from the Text state, which only `begin(State::Text)` and `Default`
    /// enter: everything `begin` resets is already reset.
    #[inline(always)]
    fn begin_from_text(&mut self, state: State) {
        debug_assert!(matches!(self.state, State::Text));
        debug_assert!(
            self.intermediates.is_empty()
                && self.params.is_empty()
                && self.prefix.is_none()
                && self.payload.is_empty()
                && !self.discard
                && self.string_utf8_remaining == 0,
            "the Text state holds no sequence state"
        );
        self.state = state;
    }
    fn begin(&mut self, state: State) {
        self.state = state;
        self.intermediates.clear();
        // A sequence has a parameter or two; moving them one at a time avoids the
        // general block copy `Vec::append` calls for it.
        while let Some(mut parameter) = self.params.pop() {
            parameter.clear();
            self.param_pool.push(parameter);
        }
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
                0x1b => self.begin_from_text(State::Escape),
                0x9b => self.begin(State::Csi),
                0x9d => self.begin(State::String(StringKind::Osc)),
                0x90 => self.begin(State::String(StringKind::Dcs)),
                0x9f => self.begin(State::String(StringKind::Apc)),
                0x9e => self.begin(State::String(StringKind::Pm)),
                0x98 => self.begin(State::String(StringKind::Sos)),
                // UTF-8 continuation bytes have already been consumed above.
                // Standalone C1 controls share the existing seven-bit ESC handlers.
                0x84 | 0x85 | 0x88 | 0x8d | 0x8e | 0x8f | 0x9a => emit(Input::Action(Action::Escape {
                    intermediates: Vec::new(), final_byte: byte - 0x40,
                })),
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

/// The length of the printable-ASCII prefix of `input`, eight bytes at a time; a
/// tail shorter than a word is left to the caller's byte loop.
#[inline(always)]
fn printable_words(input: &[u8]) -> usize {
    let (words, _) = input.as_chunks::<8>();
    for (index, word) in words.iter().enumerate() {
        let flagged = non_printable(u64::from_le_bytes(*word));
        if flagged != 0 {
            return index * 8 + (flagged.trailing_zeros() / 8) as usize;
        }
    }
    words.len() * 8
}

/// The length of the leading whole eight-byte words of printable ASCII in `input`.
#[inline(always)]
fn whole_printable_words(input: &[u8]) -> usize {
    let mut length = 0;
    while let Some(word) = input.get(length..length + 8) {
        if non_printable(u64::from_le_bytes(word.try_into().expect("eight bytes"))) != 0 {
            break;
        }
        length += 8;
    }
    length
}

/// The high bit of each byte of `word` that may not be printable ASCII (`0x20..=0x7e`).
/// The lowest flagged byte is exactly the first one that is not: each test flags a byte
/// below 0x20, a byte with the high bit set, or a 0x7f exactly, and a borrow only
/// starts at a byte below 0x20 or at a 0x7f and only reaches the bytes above it.
#[inline(always)]
fn non_printable(word: u64) -> u64 {
    const ONES: u64 = 0x0101_0101_0101_0101;
    const HIGH: u64 = 0x8080_8080_8080_8080;
    let below_space = word.wrapping_sub(ONES * 0x20) & !word & HIGH;
    let delete = (word ^ (ONES * 0x7f)).wrapping_sub(ONES) & !(word ^ (ONES * 0x7f)) & HIGH;
    below_space | delete | (word & HIGH)
}

/// Whether all eight bytes of `word` are printable ASCII.
#[cfg(test)]
fn all_printable_ascii(word: u64) -> bool {
    non_printable(word) == 0
}

#[cfg(test)]
mod tests {
    #[test]
    fn control_fast_path_matches_the_byte_machine() {
        // Every C0 byte after text, after an incomplete UTF-8 lead and in a sequence,
        // through `feed_runs` and through the byte machine alone.
        for byte in 0x00..0x20u8 {
            for lead in [&b"ab"[..], b"\xe4", b"\x1b[1", b"\x1b]2;t", b""] {
                let mut fast = Parser::default();
                let mut slow = Parser::default();
                let mut fast_actions = Vec::new();
                let mut slow_actions = Vec::new();
                fn collect(actions: &mut Vec<Action>) -> impl FnMut(Input<'_>) + '_ {
                    move |input| match input {
                        Input::Text(text, ascii) => {
                            assert_eq!(ascii, text.is_ascii());
                            actions.extend(text.chars().map(Action::Print));
                        }
                        Input::Csi(csi) => actions.push(Action::Csi(csi.clone())),
                        Input::Control(byte) => actions.push(Action::Control(byte)),
                        Input::Action(action) => actions.push(action),
                    }
                }
                let mut input = lead.to_vec();
                input.extend_from_slice(&[byte, b'z']);
                fast.feed_runs(&input, collect(&mut fast_actions));
                let mut emit = collect(&mut slow_actions);
                for &b in &input {
                    slow.byte(b, &mut emit);
                }
                drop(emit);
                assert_eq!(fast_actions, slow_actions, "{byte:#04x} after {lead:?}");
                assert_eq!(format!("{:?}", (&fast.state, fast.utf8_len, &fast.params)),
                           format!("{:?}", (&slow.state, slow.utf8_len, &slow.params)));
            }
        }
    }
    #[test]
    fn csi_fast_path_matches_the_byte_machine() {
        // Feeding one byte per call never sees an introducer whole, so it takes the
        // byte machine throughout. Whole and split feeds must produce the same actions
        // and leave the same parser state, including at the parameter limit.
        let alphabet: &[&[u8]] = &[
            b"\x1b[", b"\x1b", b"[", b"?", b">", b"<", b"=", b"0", b"1", b"9", b"65535", b"70000",
            b";", b";;", b":", b"m", b"H", b"J", b"h", b"l", b" ", b"!", b"\x7f", b"\x18", b"\x07",
            b"\x1b]", b"\x9b", b"a", b"\xe4\xb8\xad", b"\r\n",
        ];
        let limit = format!("\x1b[{}m", "1;".repeat(MAX_PARAMETERS - 1));
        let over = format!("\x1b[{}m", "1;".repeat(MAX_PARAMETERS));
        let mut state = 0x2545_f491_4f6c_dd1du64;
        for round in 0..20_000 {
            let mut bytes = Vec::new();
            if round % 50 == 0 { bytes.extend_from_slice(limit.as_bytes()); }
            if round % 50 == 1 { bytes.extend_from_slice(over.as_bytes()); }
            for _ in 0..(round % 24) + 1 {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                bytes.extend_from_slice(alphabet[(state >> 33) as usize % alphabet.len()]);
            }
            let run = |chunks: Vec<&[u8]>| {
                let mut parser = Parser::default();
                let mut actions = Vec::new();
                for chunk in chunks {
                    parser.feed(chunk, |action| actions.push(action));
                }
                // The UTF-8 scratch beyond its live length is not state.
                let live = (&parser.state, &parser.intermediates, parser.prefix, &parser.params,
                            &parser.payload, parser.discard, &parser.utf8[..parser.utf8_len],
                            parser.string_utf8_remaining);
                (actions, format!("{live:?}"))
            };
            let whole = run(vec![&bytes]);
            assert_eq!(whole, run(bytes.chunks(1).collect()), "{:?}", String::from_utf8_lossy(&bytes));
            let cut = round % (bytes.len() + 1);
            assert_eq!(whole, run(vec![&bytes[..cut], &bytes[cut..]]));
        }
    }
    #[test]
    fn word_scan_matches_the_byte_test() {
        let naive = |word: u64| {
            let first = word.to_le_bytes().iter().position(|byte| !(0x20..=0x7e).contains(byte));
            let flagged = super::non_printable(word);
            assert_eq!(first, (flagged != 0).then(|| (flagged.trailing_zeros() / 8) as usize), "{word:#x}");
            first.is_none()
        };
        // Every byte value in every lane, over printable and boundary fillers.
        for filler in [b'a', 0x20, 0x7e] {
            for lane in 0..8 {
                for byte in 0..=255u8 {
                    let mut bytes = [filler; 8];
                    bytes[lane] = byte;
                    let word = u64::from_le_bytes(bytes);
                    assert_eq!(super::all_printable_ascii(word), naive(word), "{bytes:?}");
                }
            }
        }
        // Pairs of boundary bytes, where a borrow from one lane could reach the next.
        let edges = [0x00, 0x01, 0x1f, 0x20, 0x21, 0x7e, 0x7f, 0x80, 0x9f, 0xff];
        for lane in 0..7 {
            for &a in &edges {
                for &b in &edges {
                    let mut bytes = [b'a'; 8];
                    bytes[lane] = a;
                    bytes[lane + 1] = b;
                    let word = u64::from_le_bytes(bytes);
                    assert_eq!(super::all_printable_ascii(word), naive(word), "{bytes:?}");
                }
            }
        }
        let mut state = 0x9e37_79b9_7f4a_7c15u64;
        for _ in 0..200_000 {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            // Bias toward printable lanes so both outcomes are common.
            let word = state & 0x7f7f_7f7f_7f7f_7f7f | 0x2020_2020_2020_2020 & (state >> 1);
            assert_eq!(super::all_printable_ascii(word), naive(word));
            assert_eq!(super::all_printable_ascii(state), naive(state));
        }
    }
    #[test]
    fn printable_words_stop_at_the_first_other_byte() {
        let edges = [0x00, 0x0d, 0x1b, 0x1f, 0x7f, 0x80, 0xe4, 0xff];
        for length in 0..40 {
            for at in 0..=length {
                for &edge in &edges {
                    let mut bytes = vec![b'q'; length];
                    if at < length {
                        bytes[at] = edge;
                    }
                    let first = bytes.iter().position(|byte| !(0x20..=0x7e).contains(byte)).unwrap_or(length);
                    let words = super::printable_words(&bytes);
                    // Exact inside whole words; a shorter tail is left to the byte loop.
                    assert_eq!(words, first.min(length / 8 * 8), "{length} {at} {edge:#x}");
                }
            }
        }
    }
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
    fn scalar_validation_matches_the_standard_utf8_decoder() {
        fn expected(bytes: &[u8]) -> Option<usize> {
            let width = match bytes[0] {
                0xc2..=0xdf => 2,
                0xe0..=0xef => 3,
                0xf0..=0xf4 => 4,
                _ => return None,
            };
            let sequence = bytes.get(..width)?;
            std::str::from_utf8(sequence).is_ok().then_some(width)
        }
        for value in 0..=0xff_ffffu32 {
            let bytes = value.to_be_bytes();
            let bytes = &bytes[1..];
            assert_eq!(scalar_width(bytes, 0), expected(bytes), "bytes {bytes:02x?}");
        }
        let tails = [0x00, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xff];
        for first in 0..=u8::MAX {
            for second in 0..=u8::MAX {
                for third in tails {
                    for fourth in tails {
                        let bytes = [first, second, third, fourth];
                        assert_eq!(scalar_width(&bytes, 0), expected(&bytes), "bytes {bytes:02x?}");
                    }
                }
            }
        }
        for code in 0..=0x10ffffu32 {
            let Some(ch) = char::from_u32(code) else { continue };
            let mut bytes = [0; 4];
            let bytes = ch.encode_utf8(&mut bytes).as_bytes();
            let expected = (!ch.is_ascii()).then_some(bytes.len());
            assert_eq!(scalar_width(bytes, 0), expected, "scalar {code:#x}");
        }
    }

    #[test]
    fn eight_bit_cursor_controls_match_their_escape_forms() {
        for (byte, final_byte) in [(0x84, b'D'), (0x85, b'E'), (0x88, b'H'),
                                  (0x8d, b'M'), (0x8e, b'N'), (0x8f, b'O'), (0x9a, b'Z')] {
            assert_eq!(parse(&[&[byte]]), parse(&[&[0x1b, final_byte]]), "control {byte:#x}");
        }
    }

    /// The run scan's longest prefix of `input`: printable ASCII and `scalar_width`
    /// scalars.
    fn scan_prefix(input: &[u8]) -> usize {
        let mut index = 0;
        while index < input.len() {
            if (0x20..=0x7e).contains(&input[index]) {
                index += 1;
            } else if let Some(width) = scalar_width(input, index) {
                index += width;
            } else {
                break;
            }
        }
        index
    }

    fn check_chunks(input: &[u8]) {
        let taken = text_chunks(input);
        let longest = scan_prefix(input);
        assert!(taken <= longest, "{taken} > {longest}: {input:x?}");
        assert!(std::str::from_utf8(&input[..taken]).is_ok(), "{input:x?}");
        #[cfg(target_arch = "aarch64")]
        assert!(taken + 3 >= longest / 16 * 16, "every whole chunk inside the scan's prefix: {taken} of {longest}: {input:x?}");
    }

    #[test]
    fn text_chunks_take_only_what_the_scan_takes() {
        // Every byte value at every position of a chunk inside valid text of each
        // sequence length, every pair of adjacent bytes at a chunk edge, and random
        // mixtures of valid and invalid sequences.
        let fills = ["a", "é", "中", "😀", "aé中😀", "\u{80}\u{7ff}\u{800}\u{ffff}\u{10000}\u{10ffff}\u{d7ff}\u{e000}"];
        for fill in fills {
            let base: Vec<u8> = fill.repeat(60).into_bytes();
            for at in 0..40 {
                for byte in 0..=255u8 {
                    let mut input = base.clone();
                    input[at] = byte;
                    check_chunks(&input);
                }
            }
        }
        for first in 0..=255u8 {
            for second in 0..=255u8 {
                let mut input = vec![b'a'; 48];
                input[15] = first;
                input[16] = second;
                check_chunks(&input);
                input[16] = 0x80;
                input[17] = second;
                check_chunks(&input);
            }
        }
        let pieces: [&[u8]; 14] = [
            b"a", b" ", "é".as_bytes(), "中".as_bytes(), "😀".as_bytes(), "\u{10ffff}".as_bytes(), b"\x1b",
            b"\x7f", b"\x80", b"\xc0\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xe4\xb8", b"\x9c",
        ];
        let mut state = 0x2545_f491_4f6c_dd1du64;
        for _ in 0..200_000 {
            let mut input = Vec::new();
            while input.len() < 70 {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                let piece = pieces[(state % 100) as usize % pieces.len()];
                // Mostly valid text.
                let piece = if state % 100 < 90 { pieces[(state >> 8) as usize % 6] } else { piece };
                input.extend_from_slice(piece);
            }
            check_chunks(&input);
        }
        // A sequence cut by the end of a chunk, at every lead position near it, before
        // an ASCII chunk and before a mixed one.
        for at in 10..16 {
            for lead in 0xc2..=0xf4u8 {
                for next in [b'a', 0xc3] {
                    let mut input = vec![b'a'; 64];
                    input[at] = lead;
                    for byte in &mut input[at + 1..16] {
                        *byte = 0x90;
                    }
                    if next != b'a' {
                        input[16] = next;
                        input[17] = 0xa9;
                    }
                    check_chunks(&input);
                }
            }
        }
        let line = "中文 日本語 한국어 é 😀 👩🏽\u{200d}💻 🇯🇵 text\r\n".repeat(3);
        let taken = text_chunks(line.as_bytes());
        assert!(line.is_char_boundary(taken));
        #[cfg(target_arch = "aarch64")]
        assert!(taken >= 48, "{taken}");
    }

    #[test]
    fn utf8_continuations_that_look_like_c1_controls_remain_text() {
        let text = "ĄąĈčĎďĚ";
        let expected: Vec<_> = text.chars().map(Action::Print).collect();
        for split in 0..=text.len() {
            let bytes = text.as_bytes();
            assert_eq!(parse(&[&bytes[..split], &bytes[split..]]), expected);
        }
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
                        Input::Text(text, ascii) => {
                            assert_eq!(ascii, text.is_ascii());
                            actual.extend(text.chars().map(Action::Print));
                        }
                        Input::Csi(csi) => actual.push(Action::Csi(csi.clone())),
                        Input::Control(byte) => actual.push(Action::Control(byte)),
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
