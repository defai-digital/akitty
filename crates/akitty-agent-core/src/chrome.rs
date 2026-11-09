//! Bounded chrome document for the status line and the title-bar mark.
//!
//! Terminal output and the C ABI both end in [`Chrome::apply`]. The snapshot
//! reports only what is still current. Sprites are inline RGBA; a file path,
//! URL, or shared-memory source is rejected, and nothing here decodes video.
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_STATUS_CHARS: usize = 128;
pub const MAX_SPRITE_EDGE: u32 = 32;
pub const MAX_SPRITE_FRAMES: usize = 4;
/// Cap for an `OSC 771` body. Other OSC sequences are forwarded whole: a 50_000-byte
/// clipboard is still within the decoded limit, but its base64 wire form is larger than this.
const MAX_OSC_BODY: usize = 65_536;
const CHROME_OSC: &[u8] = b"771;";
/// Cap for a forwarded (unintercepted) OSC body. The parser buffers OSC strings without
/// limit, so `printf '\e]0;'; yes` would grow memory forever. 128 KiB holds the base64 wire
/// form of the largest accepted OSC 52 clipboard (64 KiB decoded) with room to spare.
const MAX_FORWARDED_OSC: usize = 131_072;

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChromeInput {
    #[serde(default)]
    pub clear: bool,
    pub status: Option<StatusInput>,
    pub mark: Option<MarkInput>,
    pub progress: Option<ProgressInput>,
    pub sprite: Option<SpriteInput>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StatusInput {
    pub text: String,
    pub tone: String,
    pub expires: Option<u64>,
}

#[derive(Deserialize)]
#[serde(untagged)]
pub enum MarkInput {
    Frame(u8),
    Name(String),
}

#[derive(Deserialize)]
#[serde(untagged)]
pub enum ProgressInput {
    Fraction(f64),
    Indeterminate(String),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SpriteInput {
    pub w: u32,
    pub h: u32,
    pub frames: Option<Vec<String>>,
    pub path: Option<String>,
    pub file: Option<String>,
    pub url: Option<String>,
    pub uri: Option<String>,
    pub shm: Option<String>,
    pub source: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tone {
    Info,
    Warn,
    Error,
}
impl Tone {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "info" => Ok(Self::Info),
            "warn" => Ok(Self::Warn),
            "error" => Ok(Self::Error),
            _ => Err("chrome status tone must be info, warn, or error".into()),
        }
    }
    fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warn => "warn",
            Self::Error => "error",
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
enum Mark {
    Idle,
    Busy,
    Error,
    Frame(u8),
}
impl Mark {
    fn to_json(&self) -> Value {
        match self {
            Self::Idle => json!("idle"),
            Self::Busy => json!("busy"),
            Self::Error => json!("error"),
            Self::Frame(index) => json!(index),
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Progress {
    Fraction(f64),
    Indeterminate,
}
impl Progress {
    fn to_json(self) -> Value {
        match self {
            Self::Fraction(value) => json!(value),
            Self::Indeterminate => json!("indeterminate"),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
struct Sprite {
    width: u32,
    height: u32,
    frames: Vec<Vec<u8>>,
}

/// The document currently held for one session. Expired status is omitted when
/// a snapshot is built; [`Chrome::transient_visible`] is that omission.
#[derive(Clone, Default, PartialEq)]
pub struct Chrome {
    status_text: Option<String>,
    tone: Option<Tone>,
    expires_ms: Option<u64>,
    mark: Option<Mark>,
    progress: Option<Progress>,
    sprite: Option<Sprite>,
}

impl Chrome {
    pub fn apply(&mut self, input: ChromeInput) -> Result<(), String> {
        let next = if input.clear { Chrome::default() } else { Self::from_input(input)? };
        *self = next;
        Ok(())
    }

    pub fn apply_bytes(&mut self, bytes: &[u8]) -> Result<(), String> {
        let input = serde_json::from_slice(bytes).map_err(|e| format!("invalid chrome document: {e}"))?;
        self.apply(input)
    }

    /// Status text or progress that a snapshot would still report.
    pub fn transient_visible(&self, now_ms: u64) -> bool {
        !self.expired(now_ms) && (self.status_text.is_some() || self.progress.is_some())
    }

    /// When the visible status or progress expires, in Unix milliseconds. A host shows the
    /// change only when it next polls, so the session wakes it at this moment.
    pub fn expiry(&self, now_ms: u64) -> Option<u64> {
        self.expires_ms.filter(|_| self.transient_visible(now_ms))
    }

    pub fn to_json(&self, now_ms: u64) -> Option<Value> {
        let mut object = Map::new();
        if !self.expired(now_ms) {
            if let (Some(text), Some(tone)) = (&self.status_text, self.tone) {
                object.insert("status".into(), json!({"text": text, "tone": tone.as_str()}));
            }
            if let Some(progress) = self.progress {
                object.insert("progress".into(), progress.to_json());
            }
        }
        if let Some(mark) = &self.mark {
            object.insert("mark".into(), mark.to_json());
        }
        if let Some(sprite) = &self.sprite {
            let frames: Vec<String> = sprite.frames.iter().map(|frame| STANDARD.encode(frame)).collect();
            object.insert("sprite".into(), json!({"w": sprite.width, "h": sprite.height, "frames": frames}));
        }
        (!object.is_empty()).then_some(Value::Object(object))
    }

    fn expired(&self, now_ms: u64) -> bool {
        self.expires_ms.is_some_and(|expires| expires <= now_ms)
    }

    fn from_input(input: ChromeInput) -> Result<Self, String> {
        if input.clear {
            return Ok(Self::default());
        }
        if input.status.is_none() && input.mark.is_none() && input.progress.is_none() && input.sprite.is_none() {
            return Err("chrome update is empty; set clear to remove the document".into());
        }
        let (status_text, tone, expires_ms) = match input.status {
            Some(status) => {
                let text = sanitize_status(&status.text);
                let tone = Tone::parse(&status.tone)?;
                if text.is_empty() {
                    (None, None, status.expires)
                } else {
                    (Some(text), Some(tone), status.expires)
                }
            }
            None => (None, None, None),
        };
        let mark = match input.mark {
            Some(MarkInput::Name(name)) => Some(match name.as_str() {
                "idle" => Mark::Idle,
                "busy" => Mark::Busy,
                "error" => Mark::Error,
                _ => return Err("chrome mark must be idle, busy, error, or a frame 0..3".into()),
            }),
            Some(MarkInput::Frame(index)) if index < MAX_SPRITE_FRAMES as u8 => Some(Mark::Frame(index)),
            Some(MarkInput::Frame(_)) => return Err("chrome mark frame must be 0..3".into()),
            None => None,
        };
        let progress = match input.progress {
            Some(ProgressInput::Fraction(value)) if value.is_finite() && (0.0..=1.0).contains(&value) => Some(Progress::Fraction(value)),
            Some(ProgressInput::Fraction(_)) => return Err("chrome progress must be from 0 through 1, or indeterminate".into()),
            Some(ProgressInput::Indeterminate(name)) if name == "indeterminate" => Some(Progress::Indeterminate),
            Some(ProgressInput::Indeterminate(_)) => return Err("chrome progress must be from 0 through 1, or indeterminate".into()),
            None => None,
        };
        let sprite = match input.sprite {
            Some(sprite) => Some(decode_sprite(sprite)?),
            None => None,
        };
        Ok(Self { status_text, tone, expires_ms, mark, progress, sprite })
    }
}

fn sanitize_status(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).take(MAX_STATUS_CHARS).collect()
}

fn decode_sprite(sprite: SpriteInput) -> Result<Sprite, String> {
    if sprite.path.is_some() || sprite.file.is_some() || sprite.url.is_some() || sprite.uri.is_some() || sprite.shm.is_some() {
        return Err("chrome sprite rejects file, URL, and shared-memory sources".into());
    }
    if let Some(source) = sprite.source.as_deref()
        && !matches!(source, "rgba" | "inline")
    {
        return Err("chrome sprite rejects file, URL, and shared-memory sources".into());
    }
    let frames = sprite.frames.ok_or("chrome sprite needs inline RGBA frames")?;
    if sprite.w == 0 || sprite.h == 0 || sprite.w > MAX_SPRITE_EDGE || sprite.h > MAX_SPRITE_EDGE {
        return Err("chrome sprite must be 1..32 by 1..32 pixels".into());
    }
    if frames.is_empty() || frames.len() > MAX_SPRITE_FRAMES {
        return Err("chrome sprite must contain 1..4 frames".into());
    }
    let expected = sprite.w as usize * sprite.h as usize * 4;
    let mut decoded = Vec::with_capacity(frames.len());
    for frame in frames {
        let bytes = STANDARD.decode(frame.trim()).map_err(|_| "chrome sprite frame is not base64 RGBA".to_string())?;
        if bytes.len() != expected {
            return Err("chrome sprite frame does not match its width and height".into());
        }
        decoded.push(bytes);
    }
    Ok(Sprite { width: sprite.w, height: sprite.h, frames: decoded })
}

pub enum Segment {
    Pass(Vec<u8>),
    /// JSON body of one complete `OSC 771` sequence, without the introducer.
    Document(Vec<u8>),
    /// Bounded shell metadata; never grants input authority.
    Shell(Vec<u8>),
    ProgramStatus(Vec<u8>),
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Esc,
    Osc,
    OscEsc,
    /// An unintercepted OSC, already handed to the parser. Later bytes are copied through.
    Forward,
    ForwardEsc,
    /// A forwarded OSC that outgrew its cap. The parser was sent CAN; the tail is dropped.
    Discard,
    DiscardEsc,
}

/// Pulls chrome and shell metadata out before the VT parser sees it.
/// State survives chunk boundaries. Other bytes, including long OSC 52 payloads, pass unchanged.
#[derive(Default)]
pub struct Filter {
    state: State,
    buffer: Vec<u8>,
    overflow: bool,
    /// Body bytes of the current forwarded OSC handed to the parser so far.
    forwarded: usize,
}

/// True for an intercepted OSC body or a still-ambiguous prefix.
fn osc_is_intercepted(body: &[u8]) -> bool {
    [CHROME_OSC, b"133;", b"7;", b"772;", b"7501;"].iter().any(|prefix| body.starts_with(prefix) || prefix.starts_with(body))
}

impl Filter {
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<Segment> {
        let mut out = Vec::new();
        let mut pass = Vec::new();
        let mut at = 0;
        while at < bytes.len() {
            // Ground runs are copied whole; only escapes and string bodies are handled byte by byte.
            if self.state == State::Ground {
                let end = bytes[at..].iter().position(|&byte| byte == 0x1b).map_or(bytes.len(), |esc| at + esc);
                pass.extend_from_slice(&bytes[at..end]);
                at = end;
                if at == bytes.len() { break; }
                self.state = State::Esc;
                at += 1;
                continue;
            }
            let byte = bytes[at];
            loop {
                match self.state {
                    State::Ground => {
                        if byte == 0x1b {
                            self.state = State::Esc;
                        } else {
                            pass.push(byte);
                        }
                    }
                    State::Esc => {
                        if byte == b']' {
                            if !pass.is_empty() {
                                out.push(Segment::Pass(std::mem::take(&mut pass)));
                            }
                            self.state = State::Osc;
                            self.buffer.clear();
                            self.overflow = false;
                        } else {
                            pass.push(0x1b);
                            if byte != 0x1b {
                                pass.push(byte);
                                self.state = State::Ground;
                            }
                        }
                    }
                    State::Osc => match byte {
                        0x07 => self.finish(&mut out, b"\x07"),
                        0x1b => self.state = State::OscEsc,
                        // CAN and SUB cancel the string, so it cannot swallow later output.
                        0x18 | 0x1a => {
                            self.buffer.clear();
                            self.overflow = false;
                            self.state = State::Ground;
                        }
                        _ => {
                            if self.overflow {
                                // Tail of an oversized OSC 771. Discard it until the terminator.
                            } else if self.buffer.len() < MAX_OSC_BODY {
                                self.buffer.push(byte);
                                // Decide before the body can exceed the cap. OSC 52 diverges at its first byte.
                                if !osc_is_intercepted(&self.buffer) {
                                    self.forwarded = self.buffer.len();
                                    pass.extend_from_slice(b"\x1b]");
                                    pass.append(&mut self.buffer);
                                    self.state = State::Forward;
                                }
                            } else {
                                self.overflow = true;
                            }
                        }
                    },
                    State::OscEsc => {
                        if byte == b'\\' {
                            self.finish(&mut out, b"\x1b\\");
                        } else {
                            self.abort(&mut out);
                            self.state = State::Esc;
                            continue;
                        }
                    }
                    State::Forward => match byte {
                        0x07 => {
                            pass.push(0x07);
                            self.state = State::Ground;
                        }
                        0x1b => self.state = State::ForwardEsc,
                        // The parser already has the start of this OSC, so it must see the cancel too.
                        0x18 | 0x1a => {
                            pass.push(byte);
                            self.state = State::Ground;
                        }
                        _ if self.forwarded >= MAX_FORWARDED_OSC => {
                            // Cancel the parser's copy and drop the rest up to the terminator.
                            pass.push(0x18);
                            self.state = State::Discard;
                        }
                        _ => {
                            self.forwarded += 1;
                            pass.push(byte);
                        }
                    },
                    State::ForwardEsc => {
                        if byte == b'\\' {
                            pass.push(0x1b);
                            pass.push(b'\\');
                            self.state = State::Ground;
                        } else {
                            self.state = State::Esc;
                            continue;
                        }
                    }
                    State::Discard => match byte {
                        0x07 | 0x18 | 0x1a => self.state = State::Ground,
                        0x1b => self.state = State::DiscardEsc,
                        _ => {}
                    },
                    State::DiscardEsc => {
                        if byte == b'\\' {
                            self.state = State::Ground;
                        } else {
                            self.state = State::Esc;
                            continue;
                        }
                    }
                }
                break;
            }
            at += 1;
        }
        if !pass.is_empty() {
            out.push(Segment::Pass(pass));
        }
        out
    }

    fn finish(&mut self, out: &mut Vec<Segment>, terminator: &[u8]) {
        let body = std::mem::take(&mut self.buffer);
        let overflow = self.overflow;
        self.overflow = false;
        self.state = State::Ground;
        if !overflow && body.starts_with(b"771;") {
            out.push(Segment::Document(body[4..].to_vec()));
        } else if body.starts_with(b"7501;") {
            if !overflow && body.len() + 2 + terminator.len() <= 4096 {
                out.push(Segment::ProgramStatus(body[5..].to_vec()));
            }
        } else if body.starts_with(b"133;") || body.starts_with(b"7;") || body.starts_with(b"772;") {
            out.push(Segment::Shell(body));
        } else if !overflow {
            let mut bytes = vec![0x1b, b']'];
            bytes.extend_from_slice(&body);
            bytes.extend_from_slice(terminator);
            out.push(Segment::Pass(bytes));
        }
    }

    /// An ESC inside the string that is not ST. A chrome sequence is discarded
    /// so a rejected or broken document cannot change the session.
    fn abort(&mut self, out: &mut Vec<Segment>) {
        let body = std::mem::take(&mut self.buffer);
        let overflow = self.overflow;
        self.overflow = false;
        if overflow || osc_is_intercepted(&body) {
            return;
        }
        let mut bytes = vec![0x1b, b']'];
        bytes.extend_from_slice(&body);
        out.push(Segment::Pass(bytes));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn passed(segments: Vec<Segment>) -> Vec<u8> {
        segments
            .into_iter()
            .flat_map(|segment| match segment {
                Segment::Pass(bytes) => bytes,
                _ => Vec::new(),
            })
            .collect()
    }

    /// Segment kinds and bytes in order, with adjacent pass segments merged so a run
    /// split across feeds compares equal to the same run fed whole.
    fn joined(feeds: impl IntoIterator<Item = Vec<Segment>>) -> Vec<(u8, Vec<u8>)> {
        let mut out: Vec<(u8, Vec<u8>)> = Vec::new();
        for segment in feeds.into_iter().flatten() {
            let (kind, bytes) = match segment {
                Segment::Pass(bytes) => (0, bytes),
                Segment::Document(bytes) => (1, bytes),
                Segment::Shell(bytes) => (2, bytes),
                Segment::ProgramStatus(bytes) => (3, bytes),
            };
            if kind == 0
                && let Some((0, last)) = out.last_mut()
            {
                last.extend(bytes);
                continue;
            }
            out.push((kind, bytes));
        }
        out
    }

    #[test]
    fn expiry_is_reported_only_while_a_timed_status_is_visible() {
        let mut chrome = Chrome::default();
        assert_eq!(chrome.expiry(0), None);
        chrome.apply_bytes(br#"{"status":{"text":"Saved","tone":"info","expires":1000}}"#).unwrap();
        assert_eq!(chrome.expiry(999), Some(1000));
        assert_eq!(chrome.expiry(1000), None, "an expired status needs no wake");
        chrome.apply_bytes(br#"{"status":{"text":"Working","tone":"info"}}"#).unwrap();
        assert_eq!(chrome.expiry(0), None, "an untimed status never expires");
    }

    #[test]
    fn ground_runs_keep_escape_bytes_out_of_the_pass_buffer() {
        let mut filter = Filter::default();
        assert_eq!(joined([filter.feed(b"plain text")]), vec![(0, b"plain text".to_vec())]);
        // An ESC ending a chunk leaves the sequence pending for the next feed.
        assert!(joined([filter.feed(b"\x1b")]).is_empty());
        // OSC 0 is not intercepted: the whole forwarded sequence stays one pass run.
        assert_eq!(joined([filter.feed(b"]0;t\x07x")]), vec![(0, b"\x1b]0;t\x07x".to_vec())]);
        // Shell metadata leaves the pass run and resumes after it.
        assert_eq!(joined([filter.feed(b"\x1b]133;A\x07x")]), vec![(2, b"133;A".to_vec()), (0, b"x".to_vec())]);
        // An aborted chrome string is dropped and its ESC starts the next sequence.
        let mut filter = Filter::default();
        assert_eq!(joined([filter.feed(b"\x1b]771;{\x1b[31mred")]), vec![(0, b"\x1b[31mred".to_vec())]);
    }

    #[test]
    fn whole_and_split_feeds_yield_the_same_segments() {
        let stream = b"plain text\x1b]771;{}\x07more\x1b]0;title\x07\x1b]52;c;QQ==\x1b\\tail\x1b]7;file://x\x07end";
        let mut whole = Filter::default();
        let expected = joined([whole.feed(stream)]);
        assert_eq!(
            expected,
            vec![
                (0, b"plain text".to_vec()),
                (1, b"{}".to_vec()),
                // OSC 0 and OSC 52 are forwarded whole, so they stay in the pass run.
                (0, b"more\x1b]0;title\x07\x1b]52;c;QQ==\x1b\\tail".to_vec()),
                (2, b"7;file://x".to_vec()),
                (0, b"end".to_vec()),
            ]
        );
        for split in 0..=stream.len() {
            let mut filter = Filter::default();
            let got = joined([filter.feed(&stream[..split]), filter.feed(&stream[split..])]);
            assert_eq!(got, expected, "split {split}");
        }
    }

    #[test]
    fn unterminated_forwarded_osc_is_cancelled_at_the_cap() {
        let mut filter = Filter::default();
        let mut forwarded = passed(filter.feed(b"\x1b]0;"));
        let chunk = vec![b'y'; 4096];
        for _ in 0..(MAX_FORWARDED_OSC / chunk.len() + 8) {
            forwarded.extend(passed(filter.feed(&chunk)));
        }
        // The parser saw a bounded body followed by CAN, and nothing of the tail.
        assert!(forwarded.len() <= MAX_FORWARDED_OSC + 8, "{}", forwarded.len());
        assert_eq!(forwarded.last(), Some(&0x18));
        // The terminator ends the discard; later output passes through again.
        assert_eq!(passed(filter.feed(b"yyy\x07after")), b"after");
    }

    #[test]
    fn forwarded_osc_within_the_cap_is_untouched() {
        let mut filter = Filter::default();
        let body = vec![b'A'; 90_000];
        let mut input = b"\x1b]52;c;".to_vec();
        input.extend_from_slice(&body);
        input.extend_from_slice(b"\x1b\\next");
        assert_eq!(passed(filter.feed(&input)), input);
    }

    #[test]
    fn discarded_tail_honours_st_and_a_following_escape() {
        let mut filter = Filter::default();
        let mut input = b"\x1b]2;".to_vec();
        input.extend(vec![b'z'; MAX_FORWARDED_OSC + 10]);
        input.extend_from_slice(b"\x1b[31mred");
        let out = passed(filter.feed(&input));
        assert!(out.ends_with(b"\x18\x1b[31mred"));
    }
}
