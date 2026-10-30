//! Kitty graphics protocol subset.
//!
//! Supported: queries (`a=q`), direct raw RGB/RGBA transmission (`t=d`, `f=24|32`)
//! with optional zlib (`o=z`) and chunking (`m=`), placement at the cursor or of a
//! stored image (`a=T|p`), and deletion (`a=d`). Files, shared memory and PNG are
//! rejected, so terminal output can never make the core read local files.
//! Every size is bounded; see the constants below.
use base64::Engine;
use base64::alphabet;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use std::collections::HashMap;

/// Largest accepted image: 8 Mi pixels (32 MiB of RGBA).
pub const MAX_PIXELS: u64 = 8 * 1024 * 1024;
/// RGBA bytes one session may hold across all images.
pub const MAX_TOTAL_BYTES: usize = 128 * 1024 * 1024;
/// Base64 bytes accumulated for one chunked transmission.
const MAX_PENDING_BASE64: usize = 48 * 1024 * 1024;
/// One APC string (a single chunk); the protocol itself uses 4 KiB chunks.
const MAX_APC: usize = 4 * 1024 * 1024;
const MAX_PLACEMENTS: usize = 256;
const MAX_IMAGES: usize = 512;
const MAX_CELLS_SPAN: u32 = 1024;
const BASE64: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

pub enum Segment {
    Pass(Vec<u8>),
    /// Payload of an `ESC _ G ... ESC \` string, without the `G`.
    Apc(Vec<u8>),
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum ApcState {
    #[default]
    Ground,
    Esc,
    Apc,
    ApcEsc,
}

/// Splits graphics APC strings out of the byte stream before the VT parser sees it.
/// State survives chunk boundaries, so any split of the stream gives the same result.
#[derive(Default)]
pub struct ApcFilter {
    state: ApcState,
    buffer: Vec<u8>,
    overflow: bool,
}

impl ApcFilter {
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<Segment> {
        let mut out = Vec::new();
        let mut pass = Vec::new();
        for &byte in bytes {
            // A byte may be handled twice: an aborted string re-reads its ESC's follower.
            loop {
                match self.state {
                    ApcState::Ground => {
                        if byte == 0x1b {
                            self.state = ApcState::Esc;
                        } else {
                            pass.push(byte);
                        }
                    }
                    ApcState::Esc => {
                        if byte == b'_' {
                            if !pass.is_empty() {
                                out.push(Segment::Pass(std::mem::take(&mut pass)));
                            }
                            self.state = ApcState::Apc;
                            self.buffer.clear();
                            self.overflow = false;
                        } else {
                            pass.push(0x1b);
                            if byte != 0x1b {
                                pass.push(byte);
                                self.state = ApcState::Ground;
                            }
                        }
                    }
                    ApcState::Apc => match byte {
                        0x1b => self.state = ApcState::ApcEsc,
                        // CAN and SUB cancel a string, so binary noise cannot swallow output forever.
                        0x18 | 0x1a => {
                            self.buffer.clear();
                            self.state = ApcState::Ground;
                        }
                        _ if self.buffer.len() < MAX_APC => self.buffer.push(byte),
                        _ => self.overflow = true,
                    },
                    ApcState::ApcEsc => {
                        if byte == b'\\' {
                            let payload = std::mem::take(&mut self.buffer);
                            if !self.overflow && payload.first() == Some(&b'G') {
                                out.push(Segment::Apc(payload[1..].to_vec()));
                            }
                            self.state = ApcState::Ground;
                        } else {
                            // Any other ESC sequence aborts the string and is parsed normally.
                            self.buffer.clear();
                            self.state = ApcState::Esc;
                            continue;
                        }
                    }
                }
                break;
            }
        }
        if !pass.is_empty() {
            out.push(Segment::Pass(pass));
        }
        out
    }
}

pub struct Image {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    pub generation: u64,
    /// Created while the alternate screen was active; dropped when it is left.
    pub alt: bool,
}

#[derive(Clone)]
pub struct Placement {
    pub image: u32,
    pub id: u32,
    /// Grid line of the top-left cell (negative lines are scrollback).
    pub line: i32,
    pub col: usize,
    pub cols: u32,
    pub rows: u32,
    pub z: i32,
    pub alt: bool,
}

/// Terminal state a graphics command needs.
pub struct Context {
    pub line: i32,
    pub col: usize,
    pub alt: bool,
    pub cell_width: u32,
    pub cell_height: u32,
}

#[derive(Default)]
pub struct Outcome {
    pub reply: Vec<u8>,
    /// Cursor movement after a placement: (rows, cols).
    pub advance: Option<(u32, u32)>,
}

#[derive(Clone, Default)]
struct Command {
    action: u8,
    format: u32,
    medium: u8,
    compression: u8,
    width: u32,
    height: u32,
    id: u32,
    number: u32,
    placement: u32,
    more: bool,
    quiet: u8,
    cols: u32,
    rows: u32,
    z: i32,
    no_move: bool,
    delete: u8,
    /// True when the packet carries keys other than the chunk keys `m` and `q`.
    full: bool,
}

impl Command {
    fn parse(keys: &str) -> Command {
        let mut command = Command {
            action: b't',
            format: 32,
            medium: b'd',
            delete: b'a',
            ..Command::default()
        };
        for pair in keys.split(',') {
            let Some((key, value)) = pair.split_once('=') else { continue };
            if !matches!(key, "m" | "q") {
                command.full = true;
            }
            let number = value.parse::<i64>().unwrap_or(0);
            let unsigned = u32::try_from(number).unwrap_or(0);
            let letter = value.bytes().next().unwrap_or(0);
            match key {
                "a" => command.action = letter,
                "f" => command.format = unsigned,
                "t" => command.medium = letter,
                "o" => command.compression = letter,
                "s" => command.width = unsigned,
                "v" => command.height = unsigned,
                "i" => command.id = unsigned,
                "I" => command.number = unsigned,
                "p" => command.placement = unsigned,
                "m" => command.more = number == 1,
                "q" => command.quiet = unsigned.min(2) as u8,
                "c" => command.cols = unsigned,
                "r" => command.rows = unsigned,
                "z" => command.z = number.clamp(i32::MIN as i64, i32::MAX as i64) as i32,
                "C" => command.no_move = number == 1,
                "d" => command.delete = letter,
                _ => {}
            }
        }
        command
    }
}

struct Pending {
    command: Command,
    data: Vec<u8>,
}

#[derive(Default)]
pub struct Graphics {
    pub images: HashMap<u32, Image>,
    pub placements: Vec<Placement>,
    pending: Option<Pending>,
    bytes: usize,
    next_generation: u64,
    next_auto_id: u32,
}

impl Graphics {
    #[cfg(test)]
    pub fn bytes(&self) -> usize {
        self.bytes
    }

    /// Handles one APC payload (everything after `G`).
    pub fn handle(&mut self, payload: &[u8], context: &Context) -> Outcome {
        let text = String::from_utf8_lossy(payload);
        let (keys, data) = text.split_once(';').unwrap_or((text.as_ref(), ""));
        let mut command = Command::parse(keys);
        // A new full command cancels an unfinished transfer instead of being swallowed by it.
        if command.full {
            self.pending = None;
        }
        let (command, data) = if let Some(mut pending) = self.pending.take() {
            // Continuation chunks carry only m (and optionally q) plus data.
            if pending.data.len() + data.len() > MAX_PENDING_BASE64 {
                return self.fail(&pending.command, "EINVAL", "chunked data too large");
            }
            pending.data.extend_from_slice(data.as_bytes());
            if command.more {
                self.pending = Some(pending);
                return Outcome::default();
            }
            command = pending.command;
            (command, pending.data)
        } else {
            if command.more && matches!(command.action, b't' | b'T') {
                if data.len() > MAX_PENDING_BASE64 {
                    return self.fail(&command, "EINVAL", "chunked data too large");
                }
                self.pending = Some(Pending { data: data.as_bytes().to_vec(), command });
                return Outcome::default();
            }
            (command, data.as_bytes().to_vec())
        };
        match command.action {
            b'q' => {
                // A query never stores anything; it only reports whether the data would load.
                // Real probes are a pixel or two, so large ones cannot be used to burn CPU.
                let result = if u64::from(command.width) * u64::from(command.height) > 4096 {
                    Err("EINVAL:queries are limited to 4096 pixels".to_string())
                } else {
                    self.decode(&command, &data).map(|_| ())
                };
                Outcome {
                    reply: reply(&command, result.err().as_deref(), 0),
                    advance: None,
                }
            }
            b't' | b'T' => self.transmit(command, &data, context),
            b'p' => self.put(command, context),
            b'd' => {
                self.delete(&command);
                Outcome::default()
            }
            _ => self.fail(&command, "EINVAL", "unsupported action"),
        }
    }

    fn fail(&mut self, command: &Command, code: &str, message: &str) -> Outcome {
        Outcome {
            reply: reply(command, Some(&format!("{code}:{message}")), 0),
            advance: None,
        }
    }

    fn decode(&self, command: &Command, data: &[u8]) -> Result<Vec<u8>, String> {
        if command.medium != b'd' {
            return Err("ENOTSUP:only direct transmission (t=d) is supported".into());
        }
        let bytes_per_pixel = match command.format {
            24 => 3usize,
            32 => 4usize,
            _ => return Err("ENOTSUP:only raw RGB (f=24) and RGBA (f=32) are supported".into()),
        };
        if command.width == 0 || command.height == 0 {
            return Err("EINVAL:zero width or height".into());
        }
        if u64::from(command.width) * u64::from(command.height) > MAX_PIXELS {
            return Err("EINVAL:image exceeds the pixel limit".into());
        }
        let expected = command.width as usize * command.height as usize * bytes_per_pixel;
        let raw = BASE64.decode(data).map_err(|_| "EINVAL:invalid base64".to_string())?;
        let raw = match command.compression {
            0 => raw,
            b'z' => miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(&raw, expected)
                .map_err(|_| "EINVAL:invalid or oversized zlib data".to_string())?,
            _ => return Err("EINVAL:unknown compression".into()),
        };
        if raw.len() != expected {
            return Err("EINVAL:data size does not match dimensions".into());
        }
        if bytes_per_pixel == 4 {
            return Ok(raw);
        }
        let mut rgba = Vec::with_capacity(expected / 3 * 4);
        for [red, green, blue] in raw.as_chunks::<3>().0 {
            rgba.extend_from_slice(&[*red, *green, *blue, 255]);
        }
        Ok(rgba)
    }

    fn transmit(&mut self, command: Command, data: &[u8], context: &Context) -> Outcome {
        let rgba = match self.decode(&command, data) {
            Ok(rgba) => rgba,
            Err(error) => {
                return Outcome { reply: reply(&command, Some(&error), 0), advance: None };
            }
        };
        let id = if command.id != 0 {
            command.id
        } else {
            // Unnamed images get internal ids from a range clients rarely use.
            self.next_auto_id = self.next_auto_id.wrapping_add(1);
            0x8000_0000 | (self.next_auto_id & 0x7fff_ffff)
        };
        if !self.images.contains_key(&id) && self.images.len() >= MAX_IMAGES {
            return self.fail(&command, "ENOSPC", "too many images");
        }
        let old = self.images.get(&id).map_or(0, |image| image.rgba.len());
        if self.bytes - old + rgba.len() > MAX_TOTAL_BYTES {
            return self.fail(&command, "ENOSPC", "image memory limit reached");
        }
        self.bytes = self.bytes - old + rgba.len();
        self.next_generation += 1;
        self.images.insert(
            id,
            Image {
                width: command.width,
                height: command.height,
                rgba,
                generation: self.next_generation,
                alt: context.alt,
            },
        );
        let mut outcome = Outcome {
            reply: reply(&command, None, id),
            advance: None,
        };
        if command.action == b'T' {
            let mut put = command.clone();
            put.id = id;
            let placed = self.put(put, context);
            outcome.advance = placed.advance;
            if !placed.reply.is_empty() {
                outcome.reply = placed.reply;
            }
        }
        outcome
    }

    fn put(&mut self, command: Command, context: &Context) -> Outcome {
        let Some(image) = self.images.get(&command.id) else {
            return self.fail(&command, "ENOENT", "no such image");
        };
        let span = |requested: u32, pixels: u32, cell: u32| {
            let cell = cell.max(1);
            let cells = if requested > 0 { requested } else { pixels.div_ceil(cell) };
            cells.clamp(1, MAX_CELLS_SPAN)
        };
        let placement = Placement {
            image: command.id,
            id: command.placement,
            line: context.line,
            col: context.col,
            cols: span(command.cols, image.width, context.cell_width),
            rows: span(command.rows, image.height, context.cell_height),
            z: command.z,
            alt: context.alt,
        };
        let advance = (!command.no_move).then_some((placement.rows, placement.cols));
        // The same image and placement id replace each other, so animations that
        // retransmit a frame every tick do not accumulate placements.
        self.placements.retain(|existing| {
            !(existing.image == placement.image
                && existing.alt == placement.alt
                && if placement.id != 0 {
                    existing.id == placement.id
                } else {
                    existing.id == 0 && existing.line == placement.line && existing.col == placement.col
                })
        });
        if self.placements.len() >= MAX_PLACEMENTS {
            self.placements.remove(0);
        }
        self.placements.push(placement);
        Outcome { reply: reply(&command, None, command.id), advance }
    }

    fn delete(&mut self, command: &Command) {
        let free = command.delete.is_ascii_uppercase();
        match command.delete.to_ascii_lowercase() {
            b'a' => self.placements.clear(),
            b'i' => self.placements.retain(|p| {
                !(p.image == command.id && (command.placement == 0 || p.id == command.placement))
            }),
            b'z' => self.placements.retain(|p| p.z != command.z),
            _ => return,
        }
        if free {
            self.drop_unreferenced();
        }
    }

    fn drop_unreferenced(&mut self) {
        let placements = &self.placements;
        let mut freed = 0;
        self.images.retain(|id, image| {
            let keep = placements.iter().any(|p| p.image == *id);
            if !keep {
                freed += image.rgba.len();
            }
            keep
        });
        self.bytes -= freed;
    }

    /// Called when the alternate screen is left: its images and placements go with it.
    pub fn leave_alternate_screen(&mut self) {
        self.placements.retain(|p| !p.alt);
        let mut freed = 0;
        self.images.retain(|_, image| {
            if image.alt {
                freed += image.rgba.len();
            }
            !image.alt
        });
        self.bytes -= freed;
        self.pending = None;
    }

    /// Main-screen content moved up by `lines` rows into scrollback.
    pub fn scrolled(&mut self, lines: i32, history: usize) {
        for placement in self.placements.iter_mut().filter(|p| !p.alt) {
            placement.line -= lines;
        }
        let top = -(history as i32);
        self.placements.retain(|p| p.alt || p.line + p.rows as i32 > top);
    }
}

/// `ESC _ G i=..;OK|error ESC \` or nothing when the client asked for silence.
fn reply(command: &Command, error: Option<&str>, image: u32) -> Vec<u8> {
    let silent = match error {
        None => command.quiet >= 1,
        Some(_) => command.quiet >= 2,
    };
    let id = if command.id != 0 { command.id } else { image };
    if silent || (command.id == 0 && command.number == 0) {
        return Vec::new();
    }
    let mut keys = format!("i={id}");
    if command.number != 0 {
        keys.push_str(&format!(",I={}", command.number));
    }
    if command.placement != 0 {
        keys.push_str(&format!(",p={}", command.placement));
    }
    // Error text is a fixed set of ASCII messages, never client-controlled bytes.
    format!("\x1b_G{keys};{}\x1b\\", error.unwrap_or("OK")).into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> Context {
        Context { line: 0, col: 0, alt: true, cell_width: 8, cell_height: 16 }
    }
    fn encode(raw: &[u8]) -> String {
        BASE64.encode(raw)
    }

    #[test]
    fn apc_filter_is_split_invariant() {
        let stream = b"ab\x1b[1m\x1b_Gi=1;QQ==\x1b\\cd\x1b\x1b[0m\x1b_Hignored\x1b\\ef";
        let collect = |parts: &[&[u8]]| {
            let mut filter = ApcFilter::default();
            let (mut pass, mut apc) = (Vec::new(), Vec::new());
            for part in parts {
                for segment in filter.feed(part) {
                    match segment {
                        Segment::Pass(bytes) => pass.extend(bytes),
                        Segment::Apc(bytes) => apc.push(bytes),
                    }
                }
            }
            (pass, apc)
        };
        let whole = collect(&[stream]);
        assert_eq!(whole.1, vec![b"i=1;QQ==".to_vec()]);
        assert_eq!(whole.0, b"ab\x1b[1mcd\x1b\x1b[0mef");
        for split in 0..=stream.len() {
            assert_eq!(collect(&[&stream[..split], &stream[split..]]), whole, "split {split}");
        }
    }

    #[test]
    fn unterminated_strings_abort_on_cancel_or_a_new_escape_sequence() {
        let run = |stream: &[u8]| {
            let mut filter = ApcFilter::default();
            let mut pass = Vec::new();
            let mut apc = 0;
            for segment in filter.feed(stream) {
                match segment {
                    Segment::Pass(bytes) => pass.extend(bytes),
                    Segment::Apc(_) => apc += 1,
                }
            }
            (pass, apc)
        };
        assert_eq!(run(b"a\x1b_Gjunk\x18b"), (b"ab".to_vec(), 0));
        assert_eq!(run(b"a\x1b_Gjunk\x1ab"), (b"ab".to_vec(), 0));
        assert_eq!(run(b"a\x1b_Gjunk\x1b[1mb"), (b"a\x1b[1mb".to_vec(), 0));
        assert_eq!(run(b"a\x1b_Gjunk\x1b\x1b_Gi=1;AAAA\x1b\\b"), (b"a\x1bb".to_vec(), 1));
    }

    #[test]
    fn a_new_command_cancels_an_unfinished_chunked_transfer() {
        let mut graphics = Graphics::default();
        graphics.handle(b"a=T,f=32,s=99,v=99,i=1,m=1;AAAA", &context());
        graphics.handle(b"a=t,f=24,s=1,v=1,i=2,q=2;AAAA", &context());
        assert!(graphics.images.contains_key(&2));
        graphics.handle(b"a=t,f=24,s=1,v=1,i=3,m=1,q=2;AAAA", &context());
        graphics.handle(b"a=d,d=a", &context());
        // The delete ran; the half-finished transfer is gone and the next chunk starts nothing.
        assert!(graphics.images.contains_key(&2));
        assert!(graphics.handle(b"m=0;", &context()).reply.is_empty());
        assert!(!graphics.images.contains_key(&3));
    }

    #[test]
    fn image_count_and_query_size_are_bounded() {
        let mut graphics = Graphics::default();
        for id in 1..=MAX_IMAGES as u32 + 5 {
            graphics.handle(format!("a=t,f=32,s=1,v=1,i={id},q=2;AAAAAA==").as_bytes(), &context());
        }
        assert_eq!(graphics.images.len(), MAX_IMAGES);
        let big = graphics.handle(b"a=q,i=4,s=4096,v=4096,f=32;AAAA", &context());
        assert!(String::from_utf8(big.reply).unwrap().contains("limited"));
    }

    #[test]
    fn query_replies_ok_and_reports_errors() {
        let mut graphics = Graphics::default();
        let ok = graphics.handle(b"i=31337,s=1,v=1,a=q,t=d,f=24;AAAA", &context());
        assert_eq!(ok.reply, b"\x1b_Gi=31337;OK\x1b\\");
        assert!(graphics.images.is_empty());
        let bad = graphics.handle(b"i=7,s=1,v=1,a=q,t=f,f=24;AAAA", &context());
        assert!(String::from_utf8(bad.reply).unwrap().contains("ENOTSUP"));
        assert!(graphics.handle(b"i=7,s=1,v=1,a=q,q=2,t=f;AAAA", &context()).reply.is_empty());
    }

    #[test]
    fn chunked_zlib_rgb_transmit_and_place() {
        let mut graphics = Graphics::default();
        let raw: Vec<u8> = (0..16 * 32 * 3).map(|i| (i % 251) as u8).collect();
        let packed = encode(&miniz_oxide::deflate::compress_to_vec_zlib(&raw, 1));
        let (first, second) = packed.split_at(packed.len() / 2 / 4 * 4);
        let head = format!("a=T,f=24,o=z,s=16,v=32,i=5,p=1,c=2,r=3,C=1,z=1,q=2,m=1;{first}");
        assert!(graphics.handle(head.as_bytes(), &context()).reply.is_empty());
        assert!(graphics.images.is_empty());
        let outcome = graphics.handle(format!("m=0;{second}").as_bytes(), &context());
        assert!(outcome.reply.is_empty() && outcome.advance.is_none());
        let image = &graphics.images[&5];
        assert_eq!((image.width, image.height, image.rgba.len()), (16, 32, 16 * 32 * 4));
        assert_eq!(&image.rgba[..4], &[raw[0], raw[1], raw[2], 255]);
        let placement = &graphics.placements[0];
        assert_eq!((placement.cols, placement.rows, placement.z, placement.id), (2, 3, 1, 1));
    }

    #[test]
    fn retransmitting_a_frame_replaces_image_and_placement() {
        let mut graphics = Graphics::default();
        let frame = encode(&[9u8; 8 * 16 * 3]);
        for _ in 0..50 {
            graphics.handle(format!("a=T,f=24,s=8,v=16,i=5,p=1,q=2,C=1;{frame}").as_bytes(), &context());
        }
        assert_eq!((graphics.images.len(), graphics.placements.len()), (1, 1));
        assert_eq!(graphics.bytes(), 8 * 16 * 4);
        assert_eq!(graphics.images[&5].generation, 50);
    }

    #[test]
    fn rejects_unsafe_and_oversized_requests() {
        let mut graphics = Graphics::default();
        for keys in [
            "a=t,t=f,f=24,s=1,v=1,i=1",
            "a=t,t=s,f=24,s=1,v=1,i=1",
            "a=t,f=100,s=1,v=1,i=1",
            "a=t,f=24,s=100000,v=100000,i=1",
            "a=t,f=24,s=0,v=1,i=1",
            "a=t,f=24,s=2,v=2,i=1",
        ] {
            let outcome = graphics.handle(format!("{keys};AAAA").as_bytes(), &context());
            assert!(outcome.reply.starts_with(b"\x1b_Gi=1;E"), "{keys}");
        }
        assert!(graphics.images.is_empty());
        // A zlib bomb larger than the declared size is refused, not expanded.
        let bomb = encode(&miniz_oxide::deflate::compress_to_vec_zlib(&vec![0u8; 4 * 1024 * 1024], 1));
        let outcome = graphics.handle(format!("a=t,f=24,o=z,s=2,v=2,i=1;{bomb}").as_bytes(), &context());
        assert!(outcome.reply.starts_with(b"\x1b_Gi=1;EINVAL"));
    }

    #[test]
    fn memory_limit_and_delete_free_images() {
        let mut graphics = Graphics::default();
        let big = encode(&vec![0u8; 2048 * 2048 * 4]);
        let mut stored = 0;
        for id in 1..=10 {
            let outcome = graphics.handle(format!("a=t,f=32,s=2048,v=2048,i={id};{big}").as_bytes(), &context());
            if outcome.reply.ends_with(b"OK\x1b\\") {
                stored += 1;
            } else {
                assert!(String::from_utf8(outcome.reply).unwrap().contains("ENOSPC"));
            }
        }
        assert_eq!(stored, MAX_TOTAL_BYTES / (2048 * 2048 * 4));
        graphics.handle(b"a=d,d=I,i=1", &context());
        assert!(!graphics.images.contains_key(&1));
        graphics.handle(b"a=d,d=A", &context());
        assert!(graphics.images.is_empty() && graphics.bytes() == 0);
    }

    #[test]
    fn scrolling_moves_main_screen_placements_and_leaving_alt_drops_alt_ones() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        let main = Context { alt: false, ..context() };
        graphics.handle(format!("a=T,f=24,s=1,v=1,i=1,q=2;{pixel}").as_bytes(), &main);
        graphics.handle(format!("a=T,f=24,s=1,v=1,i=2,q=2;{pixel}").as_bytes(), &context());
        graphics.scrolled(2, 10);
        assert_eq!(graphics.placements.iter().find(|p| p.image == 1).unwrap().line, -2);
        assert_eq!(graphics.placements.iter().find(|p| p.image == 2).unwrap().line, 0);
        graphics.leave_alternate_screen();
        assert!(graphics.images.contains_key(&1) && !graphics.images.contains_key(&2));
        graphics.scrolled(20, 5);
        assert!(graphics.placements.is_empty());
    }
}
