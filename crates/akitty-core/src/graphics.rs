//! Kitty graphics protocol subset.
//!
//! Supported: queries (`a=q`), direct raw RGB/RGBA transmission (`t=d`, `f=24|32`)
//! and PNG (`f=100`) with optional zlib (`o=z`) and chunking (`m=`), image numbers
//! (`I=`), placement with source rectangles at the cursor or of a stored image
//! (`a=T|p`), virtual (`U=1`) and relative (`P=`,`Q=`,`H=`,`V=`) placements,
//! animation (`a=f`,`a=a`,`a=c`,`d=f`), and deletion (`a=d`). Direct, file
//! (`t=f`), temp-file (`t=t`) and shared-memory (`t=s`) transmission are
//! supported with Kitty's rules: files are read only as regular files outside
//! /dev, /proc and /sys, and every read is bounded by what the format needs.
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
/// Appended animation frames one image may hold (frame 1 is the transmission).
const MAX_FRAMES: usize = 512;
/// Frame gap in milliseconds when a frame is created without `z=`.
const DEFAULT_GAP_MS: u32 = 40;
/// Relative placements may not form chains deeper than this many links.
const MAX_CHAIN: usize = 8;
/// png decoder allocation cap; the largest legal frame decompresses to 64 MiB.
const PNG_LIMIT_BYTES: usize = 64 * 1024 * 1024 + (1 << 20);
/// Default zlib limit for `f=100` payloads sent without a size hint.
const PNG_ZLIB_LIMIT: usize = 32 * 1024 * 1024;
/// Hard ceiling for client-declared zlib limits; a bigger `S=` cannot force huge buffers.
const PNG_ZLIB_LIMIT_MAX: usize = 128 * 1024 * 1024;
const BASE64: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

pub enum Segment {
    Pass(Vec<u8>),
    /// Payload of an `ESC _ G ... ESC \` string, without the `G`.
    Apc(Vec<u8>),
    /// A consumed `CSI 16 t` cell size request; vte never sees these bytes.
    CellSizeQuery,
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum ApcState {
    #[default]
    Ground,
    Esc,
    Apc,
    ApcEsc,
    /// Inside `CSI 16 t`; the payload counts how many bytes of the sequence match.
    Csi16(u8),
}

/// `ESC [ 1 6 t`, the cell size report request this filter answers itself.
const CSI16: [u8; 5] = [0x1b, b'[', b'1', b'6', b't'];

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
                        } else if byte == b'[' {
                            // CSI strings may be the cell size request; watch for it.
                            self.state = ApcState::Csi16(2);
                        } else {
                            pass.push(0x1b);
                            if byte != 0x1b {
                                pass.push(byte);
                                self.state = ApcState::Ground;
                            }
                        }
                    }
                    ApcState::Csi16(count) => {
                        if byte == CSI16[count as usize] {
                            if count as usize == CSI16.len() - 1 {
                                if !pass.is_empty() {
                                    out.push(Segment::Pass(std::mem::take(&mut pass)));
                                }
                                out.push(Segment::CellSizeQuery);
                                self.state = ApcState::Ground;
                            } else {
                                self.state = ApcState::Csi16(count + 1);
                            }
                        } else {
                            // Not `CSI 16 t`: the consumed bytes pass through unchanged
                            // and the mismatching byte is parsed again from the ground.
                            pass.extend_from_slice(&CSI16[..count as usize]);
                            self.state = ApcState::Ground;
                            continue;
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
    /// The pixels of the frame on display; frame 1 while nothing animates.
    pub rgba: Vec<u8>,
    pub generation: u64,
    /// Created while the alternate screen was active; dropped when it is left.
    pub alt: bool,
    /// Sent with neither `i=` nor `I=`: no client can reference it again, so it is
    /// freed as soon as its last placement goes away.
    pub idless: bool,
    /// Animation frames, entry 0 being the transmitted image (frame 1). Empty until the first `a=f` materializes the
    /// root as `frames[0]`; from then on `rgba` is a copy of the frame on display.
    frames: Vec<Frame>,
    /// Playback state, created by the first animation command.
    animation: Option<Animation>,
}

impl Image {
    /// Every byte this image counts against the session budget.
    fn memory(&self) -> usize {
        self.rgba.len() + self.frames.iter().map(|frame| frame.rgba.len()).sum::<usize>()
    }

    /// Frames including the transmitted image (frame 1).
    fn frame_count(&self) -> u32 {
        self.frames.len().max(1) as u32
    }

    /// 0-based index of the frame on display.
    fn current(&self) -> usize {
        self.animation.as_ref().map_or(0, |animation| animation.current)
    }

    /// Gap of one frame (0-based) in milliseconds; 0 is gapless, which playback skips.
    fn gap(&self, index: usize) -> u32 {
        if index == 0 { self.animation.as_ref().map_or(0, |animation| animation.root_gap) } else { self.frames[index].gap_ms }
    }

    /// Pixels of one frame (0-based), writable; frame 1 of an image without frames is `rgba` itself.
    fn frame_mut(&mut self, index: usize) -> &mut Vec<u8> {
        if self.frames.is_empty() { &mut self.rgba } else { &mut self.frames[index].rgba }
    }

    fn frame(&self, index: usize) -> &[u8] {
        if self.frames.is_empty() { &self.rgba } else { &self.frames[index].rgba }
    }
}

/// One animation frame at full image size.
struct Frame {
    rgba: Vec<u8>,
    /// Milliseconds this frame is displayed; 0 is gapless. Unused for frame 1, whose gap is `Animation::root_gap`.
    gap_ms: u32,
}

/// Playback state of one image, as Kitty and Ghostty keep it.
#[derive(Default)]
struct Animation {
    /// 0 or 1 stopped (client-driven via `a=a,c=`), 2 loading (parks on the last frame), 3 running.
    state: u8,
    /// Loops to play before parking on the last frame; 0 is infinite (`v=1`).
    max_loops: u32,
    loops_done: u32,
    /// 0-based frame on display.
    current: usize,
    /// When the frame on display was first shown by a tick; `None` restarts its gap on the next tick.
    shown: Option<std::time::Instant>,
    /// Gap of frame 1, gapless until the client sets one with `a=a,r=1,z=`.
    root_gap: u32,
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
    /// Source rectangle in image pixels, already clamped; never zero-sized.
    pub src_x: u32,
    pub src_y: u32,
    pub src_w: u32,
    pub src_h: u32,
    /// Pixel offset inside the first cell, clamped below one cell.
    pub off_x: u32,
    pub off_y: u32,
    /// `U=1`: never drawn directly, never moved by scrolls and never hit by
    /// position-based deletes; only image deletion removes it.
    pub virt: bool,
    /// Relative placement: parent image id and parent placement id (`P=`,`Q=`).
    pub parent: Option<(u32, u32)>,
    /// Cell offset from the parent: `H=` columns, `V=` rows.
    pub rel: (i32, i32),
}

impl Placement {
    /// Whether the placement sits at its own grid anchor, so scrolls move it and screen clears remove it; virtual
    /// placements have none and relative ones follow their parent.
    pub fn anchored(&self) -> bool {
        !self.virt && self.parent.is_none()
    }
}

/// Terminal state a graphics command needs.
pub struct Context {
    pub line: i32,
    pub col: usize,
    pub alt: bool,
    pub rows: usize,
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
    /// Source rectangle keys `x`,`y`,`w`,`h` and offsets `X`,`Y`. In deletes `x`
    /// and `y` double as the id range or 1-based coordinates the mode needs.
    rect_x: u32,
    rect_y: u32,
    rect_w: u32,
    rect_h: u32,
    off_x: u32,
    off_y: u32,
    /// True when the packet carries keys other than the chunk keys `m`, `q` and `a=f`.
    full: bool,
    /// True when a placement key carried an empty value, which the protocol rejects.
    invalid: bool,
    /// `U=1`: store a virtual placement.
    virt: bool,
    /// `P=`/`Q=`: relative placement parent image and placement id (0 = first).
    parent_image: u32,
    parent_placement: u32,
    /// `H=`/`V=`: signed cell offset from the parent.
    rel_col: i32,
    rel_line: i32,
    /// `O=`/`S=`: where a `t=t`/`t=s` read starts and how many bytes it spans.
    offset: u64,
    read_size: u64,
    /// `z=` for animation commands, where its absence means the default gap.
    gap: Option<i32>,
}

impl Command {
    fn parse(keys: &str) -> Command {
        let mut command = Command { action: b't', format: 32, medium: b'd', delete: b'a', ..Command::default() };
        for pair in keys.split(',') {
            let Some((key, value)) = pair.split_once('=') else {
                continue;
            };
            // Continuation chunks carry only m, q and a=f besides the data.
            match key {
                "m" | "q" => {}
                "a" if value == "f" => {}
                _ => command.full = true,
            }
            if matches!(key, "x" | "y" | "w" | "h" | "X" | "Y") && value.is_empty() {
                command.invalid = true;
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
                "z" => {
                    command.z = number.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
                    command.gap = Some(command.z);
                }
                "C" => command.no_move = number == 1,
                "d" => command.delete = letter,
                "x" => command.rect_x = unsigned,
                "y" => command.rect_y = unsigned,
                "w" => command.rect_w = unsigned,
                "h" => command.rect_h = unsigned,
                "X" => command.off_x = unsigned,
                "Y" => command.off_y = unsigned,
                "U" => command.virt = number == 1,
                "P" => command.parent_image = unsigned,
                "Q" => command.parent_placement = unsigned,
                "H" => command.rel_col = number.clamp(i32::MIN as i64, i32::MAX as i64) as i32,
                "V" => command.rel_line = number.clamp(i32::MIN as i64, i32::MAX as i64) as i32,
                "O" => command.offset = number.max(0) as u64,
                "S" => command.read_size = number.max(0) as u64,
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
    /// Image number (`I=`) to image id; the newest transmission for a number wins.
    numbers: HashMap<u32, u32>,
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
        if command.invalid {
            return self.fail(&command, "EINVAL", "empty value in a placement key");
        }
        if command.id != 0 && command.number != 0 {
            return self.fail(&command, "EINVAL", "i= and I= cannot be combined");
        }
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
            if command.more && matches!(command.action, b't' | b'T' | b'f') {
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
                // PNG queries read only the header; their size comes from the file.
                let result = if command.format == 100 {
                    let payload = match command.medium {
                        b'd' => BASE64.decode(&data).map_err(|_| "EINVAL:invalid base64".to_string()),
                        b'f' | b't' | b's' => self.read_medium(&command, &data),
                        _ => Err("ENOTSUP:unknown transmission medium".to_string()),
                    };
                    payload.and_then(|raw| png_bytes(&command, &raw))
                        .and_then(|bytes| png_decode(&bytes, true))
                        .and_then(|head| query_pixel_rule(head.width, head.height))
                } else {
                    // Raw probes carry tiny real data. Temp-file and shared-memory probes consume
                    // their media just like a transmission, so clients can choose a working transport.
                    query_pixel_rule(command.width, command.height)
                        .and_then(|_| self.decode(&command, &data).map(|_| ()))
                };
                Outcome { reply: reply(&command, result.err().as_deref(), 0), advance: None }
            }
            b't' | b'T' => self.transmit(command, &data, context),
            b'p' => self.put(command, context),
            b'f' => self.add_frame(command, &data),
            b'a' => self.animate(command),
            b'c' => self.compose(command),
            b'd' => self.delete(&command, context),
            _ => self.fail(&command, "EINVAL", "unsupported action"),
        }
    }

    fn fail(&self, command: &Command, code: &str, message: &str) -> Outcome {
        Outcome { reply: reply(command, Some(&format!("{code}:{message}")), 0), advance: None }
    }

    fn decode(&self, command: &Command, data: &[u8]) -> Result<Decoded, String> {
        let payload = match command.medium {
            b'd' => BASE64.decode(data).map_err(|_| "EINVAL:invalid base64".to_string())?,
            b'f' | b't' | b's' => self.read_medium(command, data)?,
            _ => return Err("ENOTSUP:unknown transmission medium".into()),
        };
        if command.format == 100 {
            return png_bytes(command, &payload).and_then(|bytes| png_decode(&bytes, false));
        }
        let bytes_per_pixel = match command.format {
            24 => 3usize,
            32 => 4,
            _ => return Err("ENOTSUP:only raw RGB (f=24), RGBA (f=32) and PNG (f=100) are supported".into()),
        };
        if command.width == 0 || command.height == 0 {
            return Err("EINVAL:zero width or height".into());
        }
        if u64::from(command.width) * u64::from(command.height) > MAX_PIXELS {
            return Err("EINVAL:image exceeds the pixel limit".into());
        }
        let expected = command.width as usize * command.height as usize * bytes_per_pixel;
        let raw = match command.compression {
            0 => payload,
            b'z' => miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(&payload, expected)
                .map_err(|_| "EINVAL:invalid or oversized zlib data".to_string())?,
            _ => return Err("EINVAL:unknown compression".into()),
        };
        if raw.len() != expected {
            return Err("EINVAL:data size does not match dimensions".into());
        }
        if bytes_per_pixel == 4 {
            return Ok(Decoded { width: command.width, height: command.height, rgba: raw });
        }
        let mut rgba = Vec::with_capacity(expected / 3 * 4);
        for [red, green, blue] in raw.as_chunks::<3>().0 {
            rgba.extend_from_slice(&[*red, *green, *blue, 255]);
        }
        Ok(Decoded { width: command.width, height: command.height, rgba })
    }

    /// Reads the raw (not base64) payload of a `t=f`/`t=t`/`t=s` command from the medium its base64 payload names. The
    /// read is bounded by what the format can possibly need; compressed data gets the zlib bound.
    fn read_medium(&self, command: &Command, data: &[u8]) -> Result<Vec<u8>, String> {
        let max = if command.format == 100 || command.compression != 0 {
            PNG_ZLIB_LIMIT as u64
        } else {
            let bpp = match command.format {
                24 => 3u64,
                32 => 4,
                _ => return Err("ENOTSUP:only raw RGB (f=24), RGBA (f=32) and PNG (f=100) are supported".into()),
            };
            if command.width == 0 || command.height == 0 {
                return Err("EINVAL:zero width or height".into());
            }
            if u64::from(command.width) * u64::from(command.height) > MAX_PIXELS {
                return Err("EINVAL:image exceeds the pixel limit".into());
            }
            u64::from(command.width) * u64::from(command.height) * bpp
        };
        let name = BASE64.decode(data).map_err(|_| "EINVAL:invalid base64".to_string())?;
        match command.medium {
            b'f' => crate::media::read_file(&name, command.offset, command.read_size, max as usize),
            b't' => crate::media::read_temp_file(&name, command.offset, command.read_size, max as usize),
            _ => crate::media::read_shared_memory(&name, command.offset, command.read_size, max as usize),
        }
    }

    fn transmit(&mut self, command: Command, data: &[u8], context: &Context) -> Outcome {
        let decoded = match self.decode(&command, data) {
            Ok(decoded) => decoded,
            Err(error) => {
                return Outcome { reply: reply(&command, Some(&error), 0), advance: None };
            }
        };
        let id = if command.id != 0 {
            command.id
        } else {
            // Images without i= get internal ids from a range clients rarely use.
            loop {
                self.next_auto_id = self.next_auto_id.wrapping_add(1);
                let candidate = 0x8000_0000 | (self.next_auto_id & 0x7fff_ffff);
                if !self.images.contains_key(&candidate) {
                    break candidate;
                }
            }
        };
        let idless = command.id == 0 && command.number == 0;
        let exists = self.images.contains_key(&id);
        if !exists {
            while self.images.len() >= MAX_IMAGES && self.evict_one(id) {}
            if self.images.len() >= MAX_IMAGES {
                return self.fail(&command, "ENOSPC", "too many images");
            }
        }
        let old = self.images.get(&id).map_or(0, |image| image.memory());
        while self.bytes - old + decoded.rgba.len() > MAX_TOTAL_BYTES && self.evict_one(id) {}
        if self.bytes - old + decoded.rgba.len() > MAX_TOTAL_BYTES {
            return self.fail(&command, "ENOSPC", "image memory limit reached");
        }
        // Transmissions for an existing id replace it entirely: all placements
        // of the old image go first, so a=T re-creates exactly one placement.
        self.placements.retain(|placement| placement.image != id);
        self.cascade();
        self.bytes = self.bytes - old + decoded.rgba.len();
        self.next_generation += 1;
        self.images.insert(
            id,
            Image {
                width: decoded.width,
                height: decoded.height,
                rgba: decoded.rgba,
                generation: self.next_generation,
                alt: context.alt,
                idless,
                frames: Vec::new(),
                animation: None,
            },
        );
        if command.number != 0 {
            self.numbers.insert(command.number, id);
        }
        let mut outcome = Outcome { reply: reply(&command, None, id), advance: None };
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
        let id = if command.id != 0 {
            command.id
        } else if command.number != 0 {
            self.numbers.get(&command.number).copied().unwrap_or(0)
        } else {
            0
        };
        let (width, height, idless) = match self.images.get(&id) {
            Some(image) => (image.width, image.height, image.idless),
            None => return self.fail(&command, "ENOENT", "no such image"),
        };
        // A relative placement hangs off another placement and never has an
        // anchor of its own; the chain may neither loop nor exceed MAX_CHAIN.
        let parent = (command.parent_image != 0).then_some((command.parent_image, command.parent_placement));
        if let Some((parent_image, parent_placement)) = parent {
            let Some(found) = self.find_parent(parent_image, parent_placement, context.alt) else {
                return self.fail(&command, "ENOPARENT", "no such parent placement");
            };
            if let Err(code) = self.check_chain(id, command.placement, found) {
                let message = if code == "ECYCLE" { "relative placements may not loop" } else { "relative chain too deep" };
                return self.fail(&command, code, message);
            }
        }
        // Source rectangle in image pixels; w/h 0 extend to the image edge.
        if command.rect_x >= width || command.rect_y >= height {
            return self.fail(&command, "EINVAL", "empty source rectangle");
        }
        let src_w =
            if command.rect_w == 0 { width - command.rect_x } else { command.rect_w.min(width - command.rect_x) };
        let src_h =
            if command.rect_h == 0 { height - command.rect_y } else { command.rect_h.min(height - command.rect_y) };
        if src_w == 0 || src_h == 0 {
            return self.fail(&command, "EINVAL", "empty source rectangle");
        }
        // Pixel offset inside the first cell never reaches past the cell.
        let off_x = command.off_x.min(context.cell_width.saturating_sub(1));
        let off_y = command.off_y.min(context.cell_height.saturating_sub(1));
        let cell_w = u64::from(context.cell_width.max(1));
        let cell_h = u64::from(context.cell_height.max(1));
        let (w, h) = (u64::from(src_w), u64::from(src_h));
        let (cols, rows) = match (command.cols, command.rows) {
            (0, 0) => ((w + u64::from(off_x)).div_ceil(cell_w), (h + u64::from(off_y)).div_ceil(cell_h)),
            (cols, 0) => (u64::from(cols), (u64::from(cols) * cell_w * h).div_ceil(w * cell_h)),
            (0, rows) => ((u64::from(rows) * cell_h * w).div_ceil(h * cell_w), u64::from(rows)),
            (cols, rows) => (u64::from(cols), u64::from(rows)),
        };
        let placement = Placement {
            image: id,
            id: command.placement,
            line: context.line,
            col: context.col,
            cols: cols.min(MAX_CELLS_SPAN as u64).max(1) as u32,
            rows: rows.min(MAX_CELLS_SPAN as u64).max(1) as u32,
            z: command.z,
            alt: context.alt,
            src_x: command.rect_x,
            src_y: command.rect_y,
            src_w,
            src_h,
            off_x,
            off_y,
            virt: command.virt,
            parent,
            rel: (command.rel_col, command.rel_line),
        };
        // Virtual and relative placements never move the cursor.
        let advance =
            (!command.no_move && !command.virt && parent.is_none()).then_some((placement.rows, placement.cols));
        // An idless frame replaces any idless placement at the same anchor, so
        // one-image-per-frame clients such as mpv --vo=kitty do not accumulate.
        if placement.id == 0 && idless {
            let (line, col, alt) = (placement.line, placement.col, placement.alt);
            let victims: Vec<usize> = self
                .placements
                .iter()
                .enumerate()
                .filter(|(_, existing)| {
                    existing.alt == alt
                        && existing.line == line
                        && existing.col == col
                        && existing.parent.is_none()
                        && !existing.virt
                        && self.images.get(&existing.image).is_some_and(|image| image.idless)
                })
                .map(|(index, _)| index)
                .collect();
            for index in victims.iter().rev() {
                self.placements.remove(*index);
            }
        }
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
        while self.placements.len() >= MAX_PLACEMENTS {
            // Scrollback placements go first; beyond them the oldest is dropped.
            let victim = self
                .placements
                .iter()
                .position(|existing| existing.anchored() && existing.line + existing.rows as i32 <= 0)
                .unwrap_or(0);
            self.placements.remove(victim);
        }
        self.placements.push(placement);
        self.sweep();
        self.cascade();
        Outcome { reply: reply(&command, None, id), advance }
    }

    /// The image a command names by `i=` or `I=`; 0 when it names none.
    fn target(&self, command: &Command) -> u32 {
        if command.id != 0 { command.id } else { self.numbers.get(&command.number).copied().unwrap_or(0) }
    }

    /// Shows frame `index` of `id`: `rgba` becomes its pixels and the generation moves so the renderer re-uploads.
    fn show(&mut self, id: u32, index: usize) {
        let Some(image) = self.images.get_mut(&id) else { return };
        if let Some(animation) = image.animation.as_mut() { animation.current = index; }
        if !image.frames.is_empty() {
            let frame = std::mem::take(&mut image.frames[index].rgba);
            image.rgba.copy_from_slice(&frame);
            image.frames[index].rgba = frame;
        }
        self.next_generation += 1;
        image.generation = self.next_generation;
    }

    /// `a=f`: composes the transmitted pixels at `x=`,`y=` onto a new frame (a copy of frame `c=`, or filled with
    /// the `Y=` colour) or into the existing frame `r=`. `X=1` overwrites instead of alpha blending.
    fn add_frame(&mut self, mut command: Command, data: &[u8]) -> Outcome {
        let id = self.target(&command);
        if id == 0 { return self.fail(&command, "EINVAL", "image id or number required"); }
        let Some(image) = self.images.get(&id) else { return self.fail(&command, "ENOENT", "no such image") };
        let (width, height, count) = (image.width, image.height, image.frame_count());
        // Raw frame data defaults to the full image size.
        if command.format != 100 {
            if command.width == 0 { command.width = width; }
            if command.height == 0 { command.height = height; }
        }
        let piece = match self.decode(&command, data) {
            Ok(piece) => piece,
            Err(error) => return Outcome { reply: reply(&command, Some(&error), id), advance: None },
        };
        if piece.width > width || piece.height > height {
            return self.fail(&command, "EINVAL", "frame larger than the image");
        }
        let overwrite = command.off_x == 1;
        let gap = command.gap.unwrap_or(0);
        let number = if command.rows == 0 || command.rows > count { count + 1 } else { command.rows };
        if number <= count {
            // Editing a frame in place costs no memory; a gap given with it replaces the frame's gap.
            let index = number as usize - 1;
            let image = self.images.get_mut(&id).expect("image looked up above");
            compose_rect(image.frame_mut(index), width, height, &piece, command.rect_x, command.rect_y, overwrite);
            if gap != 0 {
                let gap = gap.max(0) as u32;
                if index == 0 { image.animation.get_or_insert_with(Animation::default).root_gap = gap; } else { image.frames[index].gap_ms = gap; }
            }
            if index == image.current() {
                if let Some(animation) = image.animation.as_mut() { animation.shown = None; }
                self.show(id, index);
            }
            return Outcome { reply: reply(&command, None, id), advance: None };
        }
        if count as usize >= MAX_FRAMES { return self.fail(&command, "ENOSPC", "too many animation frames"); }
        if command.cols > count { return self.fail(&command, "EINVAL", "no such base frame"); }
        let frame_len = width as usize * height as usize * 4;
        // The first added frame also materializes frame 1 as a separate copy.
        let needed = frame_len * if count == 1 { 2 } else { 1 };
        while self.bytes + needed > MAX_TOTAL_BYTES && self.evict_one(id) {}
        if self.bytes + needed > MAX_TOTAL_BYTES { return self.fail(&command, "ENOSPC", "image memory limit reached"); }
        let image = self.images.get_mut(&id).expect("eviction keeps the target image");
        if image.frames.is_empty() { image.frames.push(Frame { rgba: image.rgba.clone(), gap_ms: 0 }); }
        let mut canvas = if command.cols != 0 {
            image.frames[command.cols as usize - 1].rgba.clone()
        } else {
            let [r, g, b, a] = command.off_y.to_be_bytes();
            [r, g, b, a].repeat(width as usize * height as usize)
        };
        compose_rect(&mut canvas, width, height, &piece, command.rect_x, command.rect_y, overwrite);
        // A new frame defaults to a 40 ms gap; a negative gap makes it gapless.
        let gap_ms = if gap > 0 { gap as u32 } else if gap < 0 { 0 } else { DEFAULT_GAP_MS };
        image.frames.push(Frame { rgba: canvas, gap_ms });
        self.bytes += needed;
        Outcome { reply: reply(&command, None, id), advance: None }
    }

    /// `a=a`: sets a frame's gap (`r=`,`z=`), the frame on display (`c=`), the playback state (`s=`) and the loop
    /// count (`v=`, off by one: 1 loops forever). Success never replies; invalid values are ignored like Kitty.
    fn animate(&mut self, command: Command) -> Outcome {
        let id = self.target(&command);
        if id == 0 { return self.fail(&command, "EINVAL", "image id or number required"); }
        let Some(image) = self.images.get_mut(&id) else { return self.fail(&command, "ENOENT", "no such image") };
        let count = image.frame_count();
        image.animation.get_or_insert_with(Animation::default);
        if let Some(gap) = command.gap.filter(|gap| *gap != 0 && command.rows != 0 && command.rows <= count) {
            let (index, gap) = (command.rows as usize - 1, gap.max(0) as u32);
            if index == 0 { image.animation.as_mut().expect("created above").root_gap = gap; } else { image.frames[index].gap_ms = gap; }
        }
        let animation = image.animation.as_mut().expect("created above");
        let mut show = None;
        if command.cols != 0 && command.cols <= count && command.cols as usize - 1 != animation.current {
            animation.shown = None;
            show = Some(command.cols as usize - 1);
        }
        if (1..=3).contains(&command.width) {
            if animation.state <= 1 && command.width != 1 { animation.shown = None; }
            animation.state = command.width as u8;
            animation.loops_done = 0;
        }
        if command.height != 0 { animation.max_loops = command.height - 1; }
        if let Some(index) = show { self.show(id, index); }
        Outcome::default()
    }

    /// `a=c`: composes a `w=`x`h=` rectangle at `X=`,`Y=` of frame `r=` onto `x=`,`y=` of frame `c=` (`C=1`
    /// overwrites). Both rectangles must lie inside the image, and inside one frame they may not overlap.
    fn compose(&mut self, command: Command) -> Outcome {
        let id = self.target(&command);
        if id == 0 { return self.fail(&command, "EINVAL", "image id or number required"); }
        let Some(image) = self.images.get(&id) else { return self.fail(&command, "ENOENT", "no such image") };
        let count = image.frame_count();
        let (source, dest) = (command.rows, command.cols);
        if source == 0 || source > count { return self.fail(&command, "ENOENT", "no such source frame"); }
        if dest == 0 || dest > count { return self.fail(&command, "ENOENT", "no such destination frame"); }
        let (width, height) = (image.width, image.height);
        let w = if command.rect_w > 0 { command.rect_w } else { width };
        let h = if command.rect_h > 0 { command.rect_h } else { height };
        let fits = |x: u32, y: u32| u64::from(x) + u64::from(w) <= u64::from(width) && u64::from(y) + u64::from(h) <= u64::from(height);
        if !fits(command.rect_x, command.rect_y) { return self.fail(&command, "EINVAL", "destination rectangle out of bounds"); }
        if !fits(command.off_x, command.off_y) { return self.fail(&command, "EINVAL", "source rectangle out of bounds"); }
        if source == dest {
            let overlaps = |a: u32, b: u32, size: u32| a.max(b) < a.min(b) + size;
            if overlaps(command.off_x, command.rect_x, w) && overlaps(command.off_y, command.rect_y, h) {
                return self.fail(&command, "EINVAL", "source and destination rectangles overlap");
            }
        }
        let stride = width as usize * 4;
        let (sx, sy) = (command.off_x as usize * 4, command.off_y as usize);
        let src = image.frame(source as usize - 1);
        let piece: Vec<u8> = (0..h as usize).flat_map(|row| &src[(sy + row) * stride + sx..][..w as usize * 4]).copied().collect();
        let piece = Decoded { width: w, height: h, rgba: piece };
        let image = self.images.get_mut(&id).expect("image looked up above");
        let index = dest as usize - 1;
        compose_rect(image.frame_mut(index), width, height, &piece, command.rect_x, command.rect_y, command.no_move);
        if index == image.current() { self.show(id, index); }
        Outcome { reply: reply(&command, None, id), advance: None }
    }

    /// `d=f`/`d=F`: deletes frame `r=` (0 is frame 1, past the end the last frame) of the image `i=`/`I=` names.
    /// Without frames, `d=F` deletes the whole image and `d=f` does nothing.
    fn delete_frame(&mut self, command: &Command) {
        let id = self.target(command);
        if self.images.get(&id).is_none_or(|image| image.frames.is_empty()) {
            if command.delete == b'F' && self.images.contains_key(&id) {
                self.placements.retain(|p| p.image != id);
                self.drop_unreferenced(&[id]);
                self.cascade();
            }
            return;
        }
        let image = self.images.get_mut(&id).expect("checked above");
        let index = (command.rows.max(1).min(image.frame_count()) - 1) as usize;
        let removed = image.frames.remove(index);
        self.bytes -= removed.rgba.len();
        let animation = image.animation.get_or_insert_with(Animation::default);
        if index == 0 { animation.root_gap = image.frames[0].gap_ms; }
        let current = if animation.current > index || animation.current >= image.frames.len() {
            animation.current.saturating_sub(1).min(image.frames.len() - 1)
        } else {
            animation.current
        };
        let changed = current != animation.current || index == animation.current;
        animation.current = current;
        if changed { animation.shown = None; }
        // One frame left: it is the image again and the duplicate copy goes.
        if image.frames.len() == 1 {
            let last = image.frames.pop().expect("one frame left");
            self.bytes -= image.rgba.len();
            image.rgba = last.rgba;
            animation.current = 0;
            self.next_generation += 1;
            image.generation = self.next_generation;
        } else if changed {
            self.show(id, current);
        }
    }

    /// Advances running animations to `now`, at most one displayed frame per image per tick with no catch-up (an
    /// animation slows down rather than skipping when ticks lag). Only placed images animate. Returns true when a
    /// displayed frame changed.
    pub fn tick(&mut self, now: std::time::Instant) -> bool {
        let mut changes = Vec::new();
        for (id, image) in &mut self.images {
            let count = image.frames.len();
            let total: u64 = (0..count).map(|index| u64::from(image.gap(index))).sum();
            let Some(animation) = image.animation.as_ref() else { continue };
            if animation.state <= 1 || count == 0 || total == 0 { continue; }
            if animation.max_loops > 0 && animation.loops_done >= animation.max_loops { continue; }
            if !self.placements.iter().any(|p| p.image == *id) { continue; }
            let shown = animation.shown.filter(|at| *at <= now).unwrap_or(now);
            let due = shown + std::time::Duration::from_millis(u64::from(image.gap(animation.current)));
            let (mut index, mut loops, state, max) = (animation.current, animation.loops_done, animation.state, animation.max_loops);
            let mut advanced = false;
            if now >= due {
                loop {
                    let next = (index + 1) % count;
                    if next == 0 {
                        if state == 2 { break; }
                        loops += 1;
                        if max > 0 && loops >= max { break; }
                    }
                    index = next;
                    advanced = true;
                    if image.gap(index) != 0 { break; }
                }
            }
            let animation = image.animation.as_mut().expect("checked above");
            animation.loops_done = loops;
            animation.shown = Some(if advanced { now } else { shown });
            if advanced && index != animation.current { changes.push((*id, index)); }
        }
        let changed = !changes.is_empty();
        for (id, index) in changes { self.show(id, index); }
        changed
    }

    /// Whether some placed animation is running, so the UI should poll at the display rate.
    pub fn animating(&self) -> bool {
        self.images.iter().any(|(id, image)| {
            image.frames.len() > 1
                && image.animation.as_ref().is_some_and(|animation| {
                    animation.state >= 2 && (animation.max_loops == 0 || animation.loops_done < animation.max_loops)
                })
                && self.placements.iter().any(|p| p.image == *id)
        })
    }

    /// The placement a relative placement names: image `image` and placement id `placement` (0 matches the
    /// image's first placement on the same screen).
    fn find_parent(&self, image: u32, placement: u32, alt: bool) -> Option<usize> {
        self.placements.iter().position(|p| p.alt == alt && p.image == image && (placement == 0 || p.id == placement))
    }

    /// Refuses a relative placement whose parent chain, starting at index `parent`, loops back to the placement
    /// being created (`image`,`id`) or is longer than `MAX_CHAIN`.
    fn check_chain(&self, image: u32, id: u32, parent: usize) -> Result<(), &'static str> {
        let mut at = Some(parent);
        for _ in 0..MAX_CHAIN {
            let Some(index) = at else { return Ok(()) };
            let p = &self.placements[index];
            if p.image == image && (id == 0 || p.id == id) { return Err("ECYCLE"); }
            at = p.parent.and_then(|(image, placement)| self.find_parent(image, placement, p.alt));
        }
        if at.is_some() { Err("ETOODEEP") } else { Ok(()) }
    }

    /// Removes relative placements whose parent is gone, transitively, then frees what that unreferenced.
    fn cascade(&mut self) {
        loop {
            let orphan = self.placements.iter().position(|p| {
                p.parent.is_some_and(|(image, placement)| self.find_parent(image, placement, p.alt).is_none())
            });
            let Some(index) = orphan else { break };
            self.placements.remove(index);
        }
        self.sweep();
    }

    /// Absolute anchor of placement `index`: relative placements add their offsets up the chain. `None` when the
    /// chain ends at a virtual placement, breaks or is too deep.
    fn anchor(&self, index: usize) -> Option<(i32, i64)> {
        let mut p = &self.placements[index];
        let (mut line, mut col) = (0i64, 0i64);
        for _ in 0..=MAX_CHAIN {
            let Some((image, placement)) = p.parent else {
                if p.virt { return None; }
                return Some(((line + i64::from(p.line)).clamp(i32::MIN as i64, i32::MAX as i64) as i32, col + p.col as i64));
            };
            line += i64::from(p.rel.1);
            col += i64::from(p.rel.0);
            p = &self.placements[self.find_parent(image, placement, p.alt)?];
        }
        None
    }

    /// The placements to draw on one screen: virtual ones are left out and relative ones resolved to absolute
    /// anchors (those landing left of column 0 are clipped away).
    pub fn drawn(&self, alt: bool) -> Vec<Placement> {
        (0..self.placements.len())
            .filter(|index| self.placements[*index].alt == alt && !self.placements[*index].virt)
            .filter_map(|index| {
                let (line, col) = self.anchor(index)?;
                let mut placement = self.placements[index].clone();
                placement.line = line;
                placement.col = usize::try_from(col).ok()?;
                Some(placement)
            })
            .collect()
    }

    /// The virtual placement Unicode placeholders of `image` refer to: id `placement`, or the image's first one for 0.
    pub fn virtual_placement(&self, image: u32, placement: u32, alt: bool) -> Option<&Placement> {
        let mut virtuals = self.placements.iter().filter(|p| p.virt && p.image == image && p.alt == alt);
        if placement == 0 { virtuals.next() } else { virtuals.find(|p| p.id == placement) }
    }

    /// Runs one `a=d` command. Deletes touch only the current screen; lowercase
    /// keeps image data (except idless images), uppercase frees unreferenced data.
    fn delete(&mut self, command: &Command, context: &Context) -> Outcome {
        self.cancel_pending();
        let mode = command.delete.to_ascii_lowercase();
        if !matches!(mode, b'a' | b'c' | b'f' | b'i' | b'n' | b'p' | b'q' | b'r' | b'x' | b'y' | b'z') {
            // Deletes carry no id context, so the generic reply helper would
            // suppress this; an unknown mode is still reported (unless q=2).
            let mut outcome = self.fail(command, "EINVAL", "unknown delete mode");
            if outcome.reply.is_empty() && command.quiet < 2 {
                outcome.reply = b"\x1b_G;EINVAL:unknown delete mode\x1b\\".to_vec();
            }
            return outcome;
        }
        if mode == b'f' {
            self.delete_frame(command);
            return Outcome::default();
        }
        let free = command.delete.is_ascii_uppercase();
        // d=i and d=n both accept i= or I= (numbers resolve through the map).
        let id = if command.id != 0 {
            command.id
        } else if command.number != 0 {
            self.numbers.get(&command.number).copied().unwrap_or(0)
        } else {
            0
        };
        // Position-based modes see relative placements where they are drawn; virtual ones never match them.
        let anchors: Vec<Option<(i32, i64)>> = (0..self.placements.len()).map(|index| self.anchor(index)).collect();
        let mut index = 0;
        let covers = |p: &Placement, (top, left): (i32, i64), line: i32, col: usize| {
            top <= line && line < top + p.rows as i32 && left <= col as i64 && (col as i64) < left + i64::from(p.cols)
        };
        // x/y are 1-based character coordinates for the cell, column and row modes.
        let target_col = command.rect_x.checked_sub(1).map(|x| x as usize);
        let target_line = command.rect_y.checked_sub(1).map(|y| y as i32);
        // Images the command touched; only these may lose their data under an uppercase mode.
        let mut touched: Vec<u32> = if matches!(mode, b'i' | b'n') && id != 0 { vec![id] } else { Vec::new() };
        self.placements.retain(|p| {
            let anchor = anchors[index];
            index += 1;
            if p.alt != context.alt {
                return true;
            }
            let Some(at) = anchor.filter(|_| !p.virt) else {
                // Virtual placements and children of virtual parents go only with their image.
                let hit = match mode {
                    b'i' | b'n' => id != 0 && p.image == id && (command.placement == 0 || p.id == command.placement),
                    b'r' => p.image >= command.rect_x && p.image <= command.rect_y,
                    _ => false,
                };
                if hit && !touched.contains(&p.image) { touched.push(p.image); }
                return !hit;
            };
            let hit = match mode {
                // Visible-screen placements only; scrollback is untouched.
                b'a' => at.0 < context.rows as i32 && at.0 + p.rows as i32 > 0,
                b'i' | b'n' => {
                    id != 0 && p.image == id && (command.placement == 0 || p.id == command.placement)
                }
                b'c' => covers(p, at, context.line, context.col),
                b'p' => matches!((target_col, target_line), (Some(col), Some(line)) if covers(p, at, line, col)),
                b'q' => matches!((target_col, target_line), (Some(col), Some(line)) if p.z == command.z && covers(p, at, line, col)),
                b'x' => matches!(target_col, Some(col) if at.1 <= col as i64 && (col as i64) < at.1 + i64::from(p.cols)),
                b'y' => matches!(target_line, Some(line) if at.0 <= line && line < at.0 + p.rows as i32),
                b'z' => p.z == command.z,
                // Image id range x..=y.
                b'r' => p.image >= command.rect_x && p.image <= command.rect_y,
                _ => false,
            };
            if hit && !touched.contains(&p.image) { touched.push(p.image); }
            !hit
        });
        self.cascade();
        if free {
            self.drop_unreferenced(&touched);
        }
        Outcome::default()
    }

    /// Frees the data of the given images that no placement references any more; other unplaced images (sent with
    /// `a=t` for a later `a=p`) are kept.
    fn drop_unreferenced(&mut self, candidates: &[u32]) {
        let placements = &self.placements;
        let mut freed = 0;
        self.images.retain(|id, image| {
            let keep = !candidates.contains(id) || placements.iter().any(|p| p.image == *id);
            if !keep {
                freed += image.memory();
            }
            keep
        });
        self.bytes -= freed;
        self.prune_numbers();
    }

    /// Frees images no client can reference again once unplaced, and drops
    /// number entries whose image is gone so the map stays bounded.
    fn sweep(&mut self) {
        let placements = &self.placements;
        let mut freed = 0;
        self.images.retain(|id, image| {
            let keep = !image.idless || placements.iter().any(|p| p.image == *id);
            if !keep {
                freed += image.memory();
            }
            keep
        });
        self.bytes -= freed;
        self.prune_numbers();
    }

    fn prune_numbers(&mut self) {
        let images = &self.images;
        self.numbers.retain(|_, id| images.contains_key(id));
    }

    /// Evicts one image to make room: first those without placements, then
    /// those whose placements are all in scrollback; oldest generation first.
    /// Returns false when nothing is evictable.
    fn evict_one(&mut self, keep: u32) -> bool {
        let mut best: Option<(u8, u64, u32)> = None;
        for (id, image) in &self.images {
            if *id == keep {
                continue;
            }
            let mut category = 0;
            let mut placed = false;
            let mut scrollback_only = true;
            for placement in &self.placements {
                if placement.image != *id {
                    continue;
                }
                placed = true;
                if !placement.anchored() || placement.line + placement.rows as i32 > 0 {
                    scrollback_only = false;
                }
            }
            if placed {
                if scrollback_only {
                    category = 1;
                } else {
                    continue;
                }
            }
            if best.is_none_or(|(kind, generation, _)| (category, image.generation) < (kind, generation)) {
                best = Some((category, image.generation, *id));
            }
        }
        let Some((_, _, victim)) = best else {
            return false;
        };
        let freed = self.images.remove(&victim).map_or(0, |image| image.memory());
        self.bytes -= freed;
        self.placements.retain(|p| p.image != victim);
        self.cascade();
        true
    }

    /// Called when the alternate screen is left: its images and placements go with it.
    pub fn leave_alternate_screen(&mut self) {
        self.placements.retain(|p| !p.alt);
        self.cascade();
        let placements = &self.placements;
        let mut freed = 0;
        // An image the main screen still shows survives even if it was retransmitted on the alternate screen.
        self.images.retain(|id, image| {
            let keep = !image.alt || placements.iter().any(|p| p.image == *id);
            if !keep {
                freed += image.memory();
            }
            keep
        });
        self.bytes -= freed;
        self.prune_numbers();
        self.cancel_pending();
    }

    /// An unfinished chunked upload does not survive a screen switch.
    pub fn cancel_pending(&mut self) {
        self.pending = None;
    }

    /// A scroll of the region `[top, bottom)` on one screen by `lines` rows
    /// (`> 0` content moves up). On the main screen with `top == 0` the lines
    /// rotate into history (`rotates_history`), moving scrollback placements
    /// along; otherwise only placements anchored inside the region move, and
    /// those whose anchor leaves it are deleted.
    pub fn scroll(&mut self, alt: bool, top: i32, bottom: i32, lines: i32, rotates_history: bool, history: usize) {
        // Every linefeed at the bottom of the screen lands here, so do nothing without placements.
        if lines == 0 || self.placements.is_empty() { return; }
        let before = self.placements.len();
        if rotates_history {
            for placement in &mut self.placements {
                if !placement.alt && placement.anchored() && placement.line < bottom {
                    placement.line -= lines;
                }
            }
            let limit = -(history as i32);
            self.placements.retain(|p| p.alt || !p.anchored() || p.line + p.rows as i32 > limit);
        } else {
            // Only placements anchored inside the region move; those whose anchor leaves it are deleted. A region
            // starting at the top of the screen has nothing above it but the window edge, so an image there stays
            // until its last row is gone (the grid clip hides the rest), like text scrolling off the top.
            let inside = |line: i32, rows: u32| line < bottom && (line >= top || (top == 0 && line + rows as i32 > 0));
            self.placements.retain_mut(|placement| {
                if placement.alt != alt || !placement.anchored() || !inside(placement.line, placement.rows) {
                    return true;
                }
                placement.line -= lines;
                inside(placement.line, placement.rows)
            });
        }
        if self.placements.len() != before { self.cascade(); }
    }

    /// Removes the placements of one screen that intersect viewport lines
    /// `0..rows`; image data survives apart from idless images.
    pub fn delete_visible(&mut self, alt: bool, rows: usize) {
        self.placements.retain(|p| !(p.alt == alt && p.anchored() && p.line < rows as i32 && p.line + p.rows as i32 > 0));
        self.cascade();
    }

    /// Removes main-screen placements that live entirely in scrollback.
    pub fn delete_scrollback(&mut self) {
        self.placements.retain(|p| p.alt || !p.anchored() || p.line + p.rows as i32 > 0);
        self.cascade();
    }

    /// Moves all main placements up by `lines` (positive) after a viewport
    /// clear or resize, dropping those pushed out of history.
    pub fn shift_main(&mut self, lines: i32, history: usize) {
        for placement in &mut self.placements {
            if !placement.alt && placement.anchored() {
                placement.line -= lines;
            }
        }
        let limit = -(history as i32);
        self.placements.retain(|p| p.alt || !p.anchored() || p.line + p.rows as i32 > limit);
        self.cascade();
    }

    /// Full reset (RIS): images, placements, pending transfers and numbers.
    pub fn reset(&mut self) {
        self.images.clear();
        self.placements.clear();
        self.numbers.clear();
        self.pending = None;
        self.bytes = 0;
    }
}

/// A fully decoded transmission; PNG paths fill in dimensions from the file.
struct Decoded {
    width: u32,
    height: u32,
    rgba: Vec<u8>,
}

/// Composes `piece` onto the `width`x`height` RGBA canvas with its top-left at (`x`,`y`), clipping at the edges.
/// Alpha blending is non-premultiplied source-over; `overwrite` copies the pixels as they are.
fn compose_rect(canvas: &mut [u8], width: u32, height: u32, piece: &Decoded, x: u32, y: u32, overwrite: bool) {
    if x >= width || y >= height { return; }
    let cols = piece.width.min(width - x) as usize;
    let rows = piece.height.min(height - y) as usize;
    for row in 0..rows {
        let at = ((y as usize + row) * width as usize + x as usize) * 4;
        let dst = &mut canvas[at..at + cols * 4];
        let src = &piece.rgba[row * piece.width as usize * 4..][..cols * 4];
        if overwrite {
            dst.copy_from_slice(src);
            continue;
        }
        for (d, s) in dst.as_chunks_mut::<4>().0.iter_mut().zip(src.as_chunks::<4>().0) {
            let alpha = u32::from(s[3]);
            if alpha == 255 { d.copy_from_slice(s); continue; }
            if alpha == 0 { continue; }
            let below = u32::from(d[3]) * (255 - alpha) / 255;
            let out = alpha + below;
            for channel in 0..3 {
                d[channel] = ((u32::from(s[channel]) * alpha + u32::from(d[channel]) * below) / out) as u8;
            }
            d[3] = out as u8;
        }
    }
}

/// Queries must stay tiny: real probes are one or two pixels, so larger ones
/// cannot be used to burn CPU on decode work.
fn query_pixel_rule(width: u32, height: u32) -> Result<(), String> {
    if u64::from(width) * u64::from(height) > 4096 {
        Err("EINVAL:queries are limited to 4096 pixels".to_string())
    } else {
        Ok(())
    }
}

/// Unwraps one `f=100` payload to the PNG file bytes: base64, then optional zlib.
/// Direct transfers use `S=` as the inflate bound; for files it is the compressed read window instead.
/// Inflates `o=z` PNG data; `raw` is the payload after base64 or as read from a file or shared memory.
fn png_bytes(command: &Command, raw: &[u8]) -> Result<Vec<u8>, String> {
    match command.compression {
        0 => Ok(raw.to_vec()),
        b'z' => {
            let limit = if command.medium == b'd' && command.read_size != 0 {
                command.read_size.min(PNG_ZLIB_LIMIT_MAX as u64) as usize
            } else {
                PNG_ZLIB_LIMIT
            };
            miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(raw, limit)
                .map_err(|_| "EINVAL:invalid or oversized zlib data".to_string())
        }
        _ => Err("EINVAL:unknown compression".into()),
    }
}

/// Decodes PNG data straight to RGBA8. The decoder expands palette and sub-byte
/// gray pixels and strips 16-bit samples to 8; whatever still lacks an alpha
/// channel (gray, gray+alpha, RGB) is converted here, so every colour type and
/// bit depth normalizes to RGBA8. APNG yields only the default image.
/// `header_only` stops after the IHDR, which is all a query needs. The header
/// is checked against the pixel limit before any frame buffer is allocated,
/// and every decoder failure becomes one fixed message that never echoes
/// client bytes.
fn png_decode(bytes: &[u8], header_only: bool) -> Result<Decoded, String> {
    let bad_png = || "EBADPNG:invalid png data".to_string();
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_limits(png::Limits { bytes: PNG_LIMIT_BYTES });
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    // The pixel limit is checked against the header before any frame buffer exists.
    let (width, height) = {
        let header = decoder.read_header_info().map_err(|_| bad_png())?;
        (header.width, header.height)
    };
    if u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err("EINVAL:image exceeds the pixel limit".into());
    }
    if header_only {
        return Ok(Decoded { width, height, rgba: Vec::new() });
    }
    let mut reader = decoder.read_info().map_err(|_| bad_png())?;
    let size = reader.output_buffer_size().ok_or_else(bad_png)?;
    let mut buffer = vec![0; size];
    let output = reader.next_frame(&mut buffer).map_err(|_| bad_png())?;
    let pixels = &buffer[..output.buffer_size().min(buffer.len())];
    let rgba = match (output.color_type, output.bit_depth) {
        (png::ColorType::Rgba, png::BitDepth::Eight) => pixels.to_vec(),
        (png::ColorType::Rgb, png::BitDepth::Eight) => {
            let mut rgba = Vec::with_capacity(pixels.len() / 3 * 4);
            for [red, green, blue] in pixels.as_chunks::<3>().0 {
                rgba.extend_from_slice(&[*red, *green, *blue, 255]);
            }
            rgba
        }
        (png::ColorType::Grayscale, png::BitDepth::Eight) => {
            let mut rgba = Vec::with_capacity(pixels.len() * 4);
            for value in pixels {
                rgba.extend_from_slice(&[*value, *value, *value, 255]);
            }
            rgba
        }
        (png::ColorType::GrayscaleAlpha, png::BitDepth::Eight) => {
            let mut rgba = Vec::with_capacity(pixels.len() / 2 * 4);
            for [value, alpha] in pixels.as_chunks::<2>().0 {
                rgba.extend_from_slice(&[*value, *value, *value, *alpha]);
            }
            rgba
        }
        _ => return Err(bad_png()),
    };
    // Frame composition slices this as exactly width x height RGBA8 on the PTY worker, so never trust the decoder's
    // buffer size for that: a short buffer would panic the worker instead of failing the command.
    if rgba.len() as u64 != u64::from(output.width) * u64::from(output.height) * 4 { return Err(bad_png()); }
    Ok(Decoded { width: output.width, height: output.height, rgba })
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
        Context { line: 0, col: 0, alt: true, rows: 24, cell_width: 8, cell_height: 16 }
    }
    fn encode(raw: &[u8]) -> String {
        BASE64.encode(raw)
    }

    #[test]
    fn apc_filter_is_split_invariant() {
        // CSI 16 t is consumed while near misses (116 t, 16;2 t, 18 t) pass through.
        let stream =
            b"ab\x1b[1m\x1b_Gi=1;QQ==\x1b\\cd\x1b\x1b[0m\x1b[16t\x1b[116t\x1b[16;2t\x1b[18t\x1b_Hignored\x1b\\ef";
        let collect = |parts: &[&[u8]]| {
            let mut filter = ApcFilter::default();
            let (mut pass, mut apc, mut cell_queries) = (Vec::new(), Vec::new(), 0);
            for part in parts {
                for segment in filter.feed(part) {
                    match segment {
                        Segment::Pass(bytes) => pass.extend(bytes),
                        Segment::Apc(bytes) => apc.push(bytes),
                        Segment::CellSizeQuery => cell_queries += 1,
                    }
                }
            }
            (pass, apc, cell_queries)
        };
        let whole = collect(&[stream]);
        assert_eq!(whole.1, vec![b"i=1;QQ==".to_vec()]);
        assert_eq!(whole.0, b"ab\x1b[1mcd\x1b\x1b[0m\x1b[116t\x1b[16;2t\x1b[18tef");
        assert_eq!(whole.2, 1, "exactly CSI 16 t is consumed");
        for split in 0..=stream.len() {
            assert_eq!(collect(&[&stream[..split], &stream[split..]]), whole, "split {split}");
        }
    }

    #[test]
    fn csi_16t_ordering_keeps_passthrough_before_the_query() {
        let mut filter = ApcFilter::default();
        let segments = filter.feed(b"x\x1b[16ty\x1b[16t");
        let kinds: Vec<&str> = segments
            .iter()
            .map(|segment| match segment {
                Segment::Pass(_) => "pass",
                Segment::Apc(_) => "apc",
                Segment::CellSizeQuery => "query",
            })
            .collect();
        assert_eq!(kinds, vec!["pass", "query", "pass", "query"]);
        assert!(matches!(&segments[0], Segment::Pass(bytes) if bytes == b"x"));
        assert!(matches!(&segments[2], Segment::Pass(bytes) if bytes == b"y"));
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
                    Segment::CellSizeQuery => {}
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
    fn auto_ids_never_replace_client_images_and_retransmit_clears_placements() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        graphics.handle(format!("a=t,f=24,s=1,v=1,i=2147483649,q=2;{pixel}").as_bytes(), &context());
        graphics.handle(format!("a=t,f=24,s=1,v=1,q=2;{pixel}").as_bytes(), &context());
        assert_eq!(graphics.images.len(), 2, "unnamed image must not overwrite 0x80000001");
        let main = Context { alt: false, ..context() };
        graphics.handle(format!("a=T,f=24,s=1,v=1,i=1,q=2;{pixel}").as_bytes(), &main);
        assert!(graphics.placements.iter().any(|p| p.image == 1));
        // Retransmitting an existing id first deletes every placement of that
        // id, per the protocol; the image then has no placement to save it
        // when the alternate screen is left.
        graphics.handle(format!("a=t,f=24,s=1,v=1,i=1,q=2;{pixel}").as_bytes(), &context());
        assert!(graphics.placements.is_empty());
        graphics.leave_alternate_screen();
        assert!(!graphics.images.contains_key(&1));
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
        // "AAAA" names no file (it decodes to three zero bytes), so a file probe fails with the fixed read error.
        let bad = graphics.handle(b"i=7,s=1,v=1,a=q,t=f,f=24;AAAA", &context());
        assert!(String::from_utf8(bad.reply).unwrap().contains("EBADF"));
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
    fn memory_limit_evicts_unplaced_images_and_enospc_when_all_placed() {
        let mut graphics = Graphics::default();
        let big = encode(&vec![0u8; 2048 * 2048 * 4]);
        // Every transmission succeeds: unplaced oldest images are evicted to fit.
        let mut stored = 0;
        for id in 1..=10 {
            let outcome = graphics.handle(format!("a=t,f=32,s=2048,v=2048,i={id},q=2;{big}").as_bytes(), &context());
            if outcome.reply.is_empty() {
                stored += 1;
            }
        }
        assert_eq!(stored, 10);
        assert_eq!(graphics.images.len(), MAX_TOTAL_BYTES / (2048 * 2048 * 4));
        assert!(!graphics.images.contains_key(&1), "oldest evicted first");
        // On-screen placements pin images: once the unplaced ones are used up,
        // the memory limit fails with ENOSPC instead of evicting them.
        let pinned = Context { line: 0, col: 0, alt: false, ..context() };
        let mut enospc = 0;
        for id in 20..=30 {
            // q=1 keeps error replies visible while successes stay silent.
            let outcome = graphics.handle(format!("a=T,f=32,s=2048,v=2048,i={id},q=1,C=1;{big}").as_bytes(), &pinned);
            if !outcome.reply.is_empty() {
                enospc += 1;
                assert!(String::from_utf8(outcome.reply).unwrap().contains("ENOSPC"));
            }
        }
        // 8 remaining unplaced slots are consumed first, then the limit bites.
        assert_eq!(enospc, 3);
        assert!(graphics.images.contains_key(&20) && graphics.images.contains_key(&27));
        assert!(!graphics.images.contains_key(&28));
        assert!(graphics.placements.iter().all(|p| p.line + p.rows as i32 > 0));
        // Deletes are scoped to the current screen, so run them on the main one.
        graphics.handle(b"a=d,d=I,i=2", &pinned);
        assert!(!graphics.images.contains_key(&2));
        graphics.handle(b"a=d,d=A", &pinned);
        assert!(graphics.images.is_empty() && graphics.bytes() == 0);
    }

    #[test]
    fn scrolling_moves_main_screen_placements_and_leaving_alt_drops_alt_ones() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        let main = Context { alt: false, ..context() };
        graphics.handle(format!("a=T,f=24,s=1,v=1,i=1,q=2;{pixel}").as_bytes(), &main);
        graphics.handle(format!("a=T,f=24,s=1,v=1,i=2,q=2;{pixel}").as_bytes(), &context());
        graphics.scroll(false, 0, 24, 2, true, 10);
        assert_eq!(graphics.placements.iter().find(|p| p.image == 1).unwrap().line, -2);
        assert_eq!(graphics.placements.iter().find(|p| p.image == 2).unwrap().line, 0);
        graphics.leave_alternate_screen();
        assert!(graphics.images.contains_key(&1) && !graphics.images.contains_key(&2));
        graphics.scroll(false, 0, 24, 20, true, 5);
        assert!(graphics.placements.is_empty());
    }

    /// Encodes a tiny PNG with the dev-dependency encoder.
    fn png_file(color: png::ColorType, depth: png::BitDepth, width: u32, height: u32, pixels: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut out, width, height);
            encoder.set_color(color);
            encoder.set_depth(depth);
            encoder.write_header().unwrap().write_image_data(pixels).unwrap();
        }
        out
    }

    /// One PNG encode case: colour, depth, dimensions, input bytes, expected RGBA.
    type PngCase = (png::ColorType, png::BitDepth, u32, u32, Vec<u8>, Vec<u8>);

    #[test]
    fn png_transmit_normalizes_every_color_type_to_rgba8() {
        let mut graphics = Graphics::default();
        let cases: [PngCase; 5] = [
            (
                png::ColorType::Grayscale,
                png::BitDepth::Eight,
                2,
                1,
                vec![10, 200],
                vec![10, 10, 10, 255, 200, 200, 200, 255],
            ),
            (png::ColorType::Grayscale, png::BitDepth::Sixteen, 1, 1, vec![0x12, 0x34], vec![0x12, 0x12, 0x12, 255]),
            (png::ColorType::GrayscaleAlpha, png::BitDepth::Eight, 1, 1, vec![77, 128], vec![77, 77, 77, 128]),
            (
                png::ColorType::Rgb,
                png::BitDepth::Eight,
                2,
                1,
                vec![255, 0, 0, 0, 255, 0],
                vec![255, 0, 0, 255, 0, 255, 0, 255],
            ),
            (png::ColorType::Rgba, png::BitDepth::Eight, 1, 1, vec![1, 2, 3, 4], vec![1, 2, 3, 4]),
        ];
        for (index, (color, depth, width, height, pixels, expected)) in cases.into_iter().enumerate() {
            let id = index as u32 + 1;
            let file = png_file(color, depth, width, height, &pixels);
            // s= and v= are ignored for PNG; dimensions come from the file itself.
            let keys = format!("a=t,f=100,s=9999,v=9999,i={id},q=1");
            let outcome = graphics.handle(format!("{keys};{}", encode(&file)).as_bytes(), &context());
            assert!(outcome.reply.is_empty(), "case {id}: {:?}", String::from_utf8_lossy(&outcome.reply));
            let image = &graphics.images[&id];
            assert_eq!((image.width, image.height), (width, height), "case {id}");
            assert_eq!(image.rgba, expected, "case {id}");
        }
    }

    #[test]
    fn png_palette_and_gray_low_depth_expand() {
        let mut graphics = Graphics::default();
        let palette = vec![255, 0, 0, 0, 255, 0];
        let mut indexed = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut indexed, 2, 1);
            encoder.set_color(png::ColorType::Indexed);
            encoder.set_depth(png::BitDepth::Eight);
            encoder.set_palette(palette.clone());
            encoder.write_header().unwrap().write_image_data(&[0, 1]).unwrap();
        }
        graphics.handle(format!("a=t,f=100,i=1,q=2;{}", encode(&indexed)).as_bytes(), &context());
        assert_eq!(graphics.images[&1].rgba, vec![255, 0, 0, 255, 0, 255, 0, 255]);
        // 1-bit grayscale packs eight pixels per byte, MSB first.
        let gray1 = png_file(png::ColorType::Grayscale, png::BitDepth::One, 8, 1, &[0b1010_1010]);
        let gray1_outcome = graphics.handle(format!("a=t,f=100,i=2,q=1;{}", encode(&gray1)).as_bytes(), &context());
        assert!(graphics.images.contains_key(&2), "gray1: {:?}", String::from_utf8_lossy(&gray1_outcome.reply));
        assert_eq!(graphics.images[&2].rgba[0..4], [255, 255, 255, 255]);
        assert_eq!(graphics.images[&2].rgba[4..8], [0, 0, 0, 255]);
        assert_eq!(graphics.images[&2].rgba[28..32], [0, 0, 0, 255]);
    }

    #[test]
    fn png_oversized_header_is_rejected_before_decoding() {
        let mut graphics = Graphics::default();
        let wide = png_file(png::ColorType::Grayscale, png::BitDepth::Eight, 2897, 2897, &vec![0u8; 2897 * 2897]);
        let outcome = graphics.handle(format!("a=t,f=100,i=1;{}", encode(&wide)).as_bytes(), &context());
        let text = String::from_utf8(outcome.reply).unwrap();
        assert!(text.contains("EINVAL") && text.contains("pixel limit"), "{text}");
        assert!(graphics.images.is_empty());
    }

    #[test]
    fn png_corrupt_data_is_rejected_with_a_fixed_message() {
        let mut graphics = Graphics::default();
        let junk = encode(b"\x89PNG\r\n\x1a\nnot-a-png-at-all");
        let outcome = graphics.handle(format!("a=t,f=100,i=1;{junk}").as_bytes(), &context());
        assert_eq!(outcome.reply, b"\x1b_Gi=1;EBADPNG:invalid png data\x1b\\");
        assert!(graphics.images.is_empty());
    }

    #[test]
    fn png_zlib_wrapped_transmit_honours_the_size_hint() {
        let mut graphics = Graphics::default();
        let file = png_file(png::ColorType::Rgba, png::BitDepth::Eight, 2, 2, &[7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]);
        let packed = encode(&miniz_oxide::deflate::compress_to_vec_zlib(&file, 1));
        // s=/v= are pixel dimensions, not the inflate bound: only S= sizes the zlib output.
        let ok = graphics.handle(format!("a=t,f=100,o=z,s=2,v=2,S={},i=1,q=2;{packed}", file.len()).as_bytes(), &context());
        assert!(ok.reply.is_empty());
        assert_eq!(graphics.images[&1].rgba, vec![7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]);
        // A too-small S= still refuses even though s= is large enough.
        let outcome = graphics.handle(format!("a=t,f=100,o=z,s=9999,v=9999,S=4,i=2;{packed}").as_bytes(), &context());
        assert!(String::from_utf8(outcome.reply).unwrap().contains("EINVAL"));
        assert!(!graphics.images.contains_key(&2));
    }

    #[test]
    fn png_zlib_temp_file_size_selects_only_the_compressed_read_window() {
        let mut graphics = Graphics::default();
        let mut file = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut file, 64, 64);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            encoder.set_compression(png::Compression::NoCompression);
            encoder.write_header().unwrap().write_image_data(&vec![7; 64 * 64 * 4]).unwrap();
        }
        let packed = miniz_oxide::deflate::compress_to_vec_zlib(&file, 1);
        assert!(packed.len() < file.len());
        let path = std::env::temp_dir().join(format!("tty-graphics-protocol-akitty-zlib-{}.png", std::process::id()));
        std::fs::write(&path, &packed).unwrap();
        let name = encode(path.as_os_str().as_encoded_bytes());
        let outcome = graphics.handle(format!("a=T,t=t,f=100,o=z,S={},i=1,q=1;{name}", packed.len()).as_bytes(), &context());
        assert!(outcome.reply.is_empty(), "{}", String::from_utf8_lossy(&outcome.reply));
        assert_eq!(graphics.images[&1].rgba, vec![7; 64 * 64 * 4]);
        assert!(!path.exists());
    }

    #[test]
    fn png_query_decodes_only_the_header() {
        let mut graphics = Graphics::default();
        let small = png_file(png::ColorType::Rgba, png::BitDepth::Eight, 3, 3, &[0u8; 36]);
        let ok = graphics.handle(format!("i=7,a=q,f=100;{}", encode(&small)).as_bytes(), &context());
        assert_eq!(ok.reply, b"\x1b_Gi=7;OK\x1b\\");
        assert!(graphics.images.is_empty());
        // 100x100 exceeds the 4096-pixel query rule using the PNG dimensions.
        let big = png_file(png::ColorType::Rgba, png::BitDepth::Eight, 100, 100, &[0u8; 40000]);
        let limited = graphics.handle(format!("i=8,a=q,f=100;{}", encode(&big)).as_bytes(), &context());
        assert!(String::from_utf8(limited.reply).unwrap().contains("limited"));
    }

    #[test]
    fn png_queries_through_files_use_header_dimensions_and_preserve_consumption_rules() {
        for medium in ['f', 't'] {
            for size in [3, 100] {
                for compressed in [false, true] {
                    let png = png_file(png::ColorType::Rgba, png::BitDepth::Eight, size, size, &vec![0; (size * size * 4) as usize]);
                    let payload = if compressed { miniz_oxide::deflate::compress_to_vec_zlib(&png, 1) } else { png };
                    let path = std::env::temp_dir().join(format!("tty-graphics-protocol-query-{}-{medium}-{size}-{compressed}.png", std::process::id()));
                    std::fs::write(&path, &payload).unwrap();
                    let name = encode(path.as_os_str().as_encoded_bytes());
                    // PNG dimensions come from its header, never the declared s/v fields.
                    let declared = if size == 3 { 100 } else { 1 };
                    let compression = if compressed { ",o=z" } else { "" };
                    let mut graphics = Graphics::default();
                    let outcome = graphics.handle(format!("i=9,a=q,t={medium},f=100,s={declared},v={declared}{compression};{name}").as_bytes(), &context());
                    let preserved = path.exists();
                    if preserved { std::fs::remove_file(&path).unwrap(); }
                    assert_eq!(preserved, medium == 'f', "only temp-file queries consume the file");
                    let reply = String::from_utf8(outcome.reply).unwrap();
                    if size == 3 { assert!(reply.contains(";OK"), "{medium} {compressed}: {reply}"); }
                    else { assert!(reply.contains("limited"), "{medium} {compressed}: {reply}"); }
                    assert!(graphics.images.is_empty());
                }
            }
        }
    }

    #[test]
    fn image_numbers_are_assigned_resolved_and_pruned() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        // i= and I= together are rejected.
        let both = graphics.handle(format!("a=t,f=24,s=1,v=1,i=1,I=2;{pixel}").as_bytes(), &context());
        assert!(String::from_utf8(both.reply).unwrap().contains("EINVAL"));
        assert!(graphics.images.is_empty());
        // A numbered transmission without i= gets a fresh id and echoes both keys.
        let assigned = graphics.handle(format!("a=t,f=24,s=1,v=1,I=7;{pixel}").as_bytes(), &context());
        let id = graphics.images.keys().copied().next().unwrap();
        assert_eq!(String::from_utf8(assigned.reply).unwrap(), format!("\x1b_Gi={id},I=7;OK\x1b\\"));
        // a=p with I= resolves through the number map.
        let below = Context { line: 3, col: 2, ..context() };
        graphics.handle(b"a=p,I=7,q=2", &below);
        let placement = graphics.placements.iter().find(|p| p.image == id).unwrap();
        assert_eq!((placement.line, placement.col), (3, 2));
        // d=n with I= deletes the numbered image's placements; lowercase keeps data.
        graphics.handle(b"a=d,d=n,I=7", &context());
        assert!(graphics.placements.is_empty());
        assert!(graphics.images.contains_key(&id));
        // Newest transmission for a number wins; d=N frees only that newest image (older ones keep their ids).
        graphics.handle(format!("a=t,f=24,s=1,v=1,I=7,q=2;{pixel}").as_bytes(), &context());
        let newest = graphics.numbers[&7];
        graphics.handle(b"a=d,d=N,I=7", &context());
        assert!(!graphics.images.contains_key(&newest));
        assert_eq!(graphics.images.len(), 1, "the earlier numbered image keeps its data");
        // The map entry died with its images, so a later lookup fails cleanly.
        let gone = graphics.handle(b"a=p,I=7", &context());
        assert!(String::from_utf8(gone.reply).unwrap().contains("ENOENT"));
    }

    #[test]
    fn idless_frames_at_one_anchor_stay_bounded() {
        let mut graphics = Graphics::default();
        // mpv --vo=kitty sends a=T,f=24,C=1,q=2 with no i= for every frame.
        let frame = encode(&vec![7u8; 64 * 64 * 3]);
        for _ in 0..500 {
            graphics.handle(format!("a=T,f=24,s=64,v=64,C=1,q=2;{frame}").as_bytes(), &context());
        }
        assert_eq!(graphics.images.len(), 1);
        assert_eq!(graphics.placements.len(), 1);
        assert_eq!(graphics.bytes(), 64 * 64 * 4);
    }

    #[test]
    fn retransmit_without_placement_removes_old_placements() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        graphics.handle(format!("a=T,f=24,s=1,v=1,i=5,q=2,C=1;{pixel}").as_bytes(), &context());
        let below = Context { line: 4, ..context() };
        graphics.handle(b"a=p,i=5,q=2", &below);
        assert_eq!(graphics.placements.len(), 2);
        // A plain a=t for an existing id deletes all of its placements.
        graphics.handle(format!("a=t,f=24,s=1,v=1,i=5,q=2;{pixel}").as_bytes(), &context());
        assert!(graphics.placements.is_empty());
        assert!(graphics.images.contains_key(&5));
    }

    #[test]
    fn placement_overflow_evicts_scrollback_first() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        let main = Context { alt: false, ..context() };
        graphics.handle(format!("a=t,f=24,s=1,v=1,i=1,q=2;{pixel}").as_bytes(), &main);
        for index in 0..MAX_PLACEMENTS as i32 {
            let at = Context { line: index, alt: false, ..context() };
            graphics.handle(format!("a=p,i=1,p={},q=2", index + 1).as_bytes(), &at);
        }
        assert_eq!(graphics.placements.len(), MAX_PLACEMENTS);
        // A 20-line scroll rotates the viewport: the anchors that end above
        // line 0 (20 of the 24 viewport-anchored ones) land in scrollback.
        graphics.scroll(false, 0, 24, 20, true, 5000);
        let scrollback =
            |graphics: &Graphics| graphics.placements.iter().filter(|p| p.line + p.rows as i32 <= 0).count();
        assert_eq!(scrollback(&graphics), 20);
        for index in 0..10 {
            let at = Context { line: index, col: 5, alt: false, ..context() };
            graphics.handle(b"a=p,i=1,q=2", &at);
        }
        assert_eq!(graphics.placements.len(), MAX_PLACEMENTS);
        assert_eq!(scrollback(&graphics), 10, "only scrollback victims go");
    }

    #[test]
    fn placement_keys_clamp_source_rect_offsets_and_derive_spans() {
        let mut graphics = Graphics::default();
        // A square 16x16 image on 8x16 cells.
        let pixels = encode(&vec![9u8; 16 * 16 * 3]);
        graphics.handle(
            format!("a=T,f=24,s=16,v=16,i=1,q=2,C=1,x=4,y=8,w=100,h=0,X=100,Y=100;{pixels}").as_bytes(),
            &context(),
        );
        let placement = &graphics.placements[0];
        // x=4,y=8 with w clamped to the image edge and h=0 meaning "to the edge".
        assert_eq!((placement.src_x, placement.src_y, placement.src_w, placement.src_h), (4, 8, 12, 8));
        // Offsets clamp below one cell.
        assert_eq!((placement.off_x, placement.off_y), (7, 15));
        // The default span includes the offsets: cols ceil((12+7)/8)=3, rows ceil((8+15)/16)=2.
        assert_eq!((placement.cols, placement.rows), (3, 2));

        // Neither c nor r: the offsets extend the default span the same way.
        graphics.handle(format!("a=p,i=1,q=2,C=1,X=4,Y=8;{pixels}").as_bytes(), &context());
        let full = graphics.placements.iter().find(|p| p.src_x == 0).unwrap();
        assert_eq!((full.cols, full.rows), (3, 2), "ceil((16+4)/8), ceil((16+8)/16)");

        // Only c given: rows follow the source aspect ratio.
        graphics.handle(b"a=p,i=1,q=2,C=1,c=4", &context());
        let derived = graphics.placements.iter().rev().find(|p| p.cols == 4).unwrap();
        assert_eq!(derived.rows, 2, "4 cols * 8 px wide of a square image = 32 px tall = 2 rows of 16 px");
        // Only r given: cols follow the source aspect ratio.
        graphics.handle(b"a=p,i=1,q=2,C=1,r=2", &context());
        let derived = graphics.placements.iter().rev().find(|p| p.rows == 2).unwrap();
        assert_eq!(derived.cols, 4, "2 rows * 16 px tall of a square image = 32 px wide = 4 cols of 8 px");
        // Both given: stretch, no aspect preservation.
        graphics.handle(b"a=p,i=1,q=2,C=1,c=5,r=3", &context());
        let stretched = graphics.placements.iter().rev().find(|p| p.cols == 5).unwrap();
        assert_eq!(stretched.rows, 3);
    }

    #[test]
    fn placement_keys_reject_empty_rectangles_and_empty_values() {
        let mut graphics = Graphics::default();
        let pixels = encode(&[9u8; 4 * 4 * 3]);
        graphics.handle(format!("a=t,f=24,s=4,v=4,i=1,q=2;{pixels}").as_bytes(), &context());
        // The source rectangle starts past the image.
        let edge = graphics.handle(b"a=p,i=1,x=4,y=0,q=1", &context());
        assert!(String::from_utf8(edge.reply).unwrap().contains("EINVAL"));
        // An empty value for a placement key is invalid.
        let empty = graphics.handle(b"a=p,i=1,x=,q=1", &context());
        assert!(String::from_utf8(empty.reply).unwrap().contains("EINVAL"));
        let empty_cap = graphics.handle(b"a=t,f=24,s=1,v=1,i=2,X=;AAAA", &context());
        assert!(String::from_utf8(empty_cap.reply).unwrap().contains("EINVAL"));
        assert!(graphics.placements.is_empty());
    }

    /// One placed 1x1 image per id at the given cell; ids are 1-based anchors.
    fn grid_of_placements(graphics: &mut Graphics, anchors: &[(i32, usize)]) {
        let pixel = encode(&[1, 2, 3]);
        for (index, (line, col)) in anchors.iter().enumerate() {
            let id = index as u32 + 1;
            graphics.handle(format!("a=t,f=24,s=1,v=1,i={id},q=2;{pixel}").as_bytes(), &context());
            let at = Context { line: *line, col: *col, ..context() };
            graphics.handle(format!("a=p,i={id},q=2").as_bytes(), &at);
        }
    }

    #[test]
    fn delete_modes_target_cells_columns_rows_and_ids() {
        let mut graphics = Graphics::default();
        let anchors: [(i32, usize); 7] = [(0, 0), (0, 4), (2, 0), (2, 6), (5, 0), (9, 0), (9, 9)];
        grid_of_placements(&mut graphics, &anchors);
        assert_eq!(graphics.placements.len(), 7);
        let images_of = |graphics: &Graphics| -> Vec<u32> {
            let mut ids: Vec<u32> = graphics.placements.iter().map(|p| p.image).collect();
            ids.sort_unstable();
            ids
        };

        // d=c removes the placement covering the cursor cell.
        let cursor = Context { line: 2, col: 6, ..context() };
        graphics.handle(b"a=d,d=c", &cursor);
        assert_eq!(images_of(&graphics), vec![1, 2, 3, 5, 6, 7]);
        // d=p uses 1-based x=column, y=row.
        graphics.handle(b"a=d,d=p,x=1,y=1", &context());
        assert_eq!(images_of(&graphics), vec![2, 3, 5, 6, 7]);
        // d=q is d=p plus a z match; the placements have z=0, so z=1 misses.
        graphics.handle(b"a=d,d=q,x=5,y=1,z=1", &context());
        assert_eq!(images_of(&graphics), vec![2, 3, 5, 6, 7]);
        graphics.handle(b"a=d,d=q,x=1,y=6,z=0", &context());
        assert_eq!(images_of(&graphics), vec![2, 3, 6, 7]);
        // d=y removes a whole row (1-based): row 10 covers both line-9 anchors.
        graphics.handle(b"a=d,d=y,y=10", &context());
        assert_eq!(images_of(&graphics), vec![2, 3]);
        // d=x removes a whole column (1-based).
        graphics.handle(b"a=d,d=x,x=5", &context());
        assert_eq!(images_of(&graphics), vec![3]);
        // d=z with no match changes nothing.
        graphics.handle(b"a=d,d=z,z=9", &context());
        assert_eq!(images_of(&graphics), vec![3]);
        // d=r removes an id range; lowercase keeps the (named) image data.
        graphics.handle(b"a=d,d=r,x=3,y=5", &context());
        assert!(graphics.placements.is_empty());
        assert_eq!(graphics.images.len(), 7, "lowercase keeps named data");
        // d=f is accepted as a no-op and unknown modes are EINVAL replies.
        assert!(graphics.handle(b"a=d,d=f", &context()).reply.is_empty());
        let unknown = graphics.handle(b"a=d,d=K,q=1", &context());
        assert!(String::from_utf8(unknown.reply).unwrap().contains("EINVAL"));
    }

    #[test]
    fn delete_a_hits_only_visible_placements_of_the_current_screen() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        let main = Context { alt: false, ..context() };
        graphics.handle(format!("a=T,f=24,s=1,v=1,i=1,q=2;{pixel}").as_bytes(), &main);
        graphics.handle(format!("a=T,f=24,s=1,v=1,i=2,q=2;{pixel}").as_bytes(), &context());
        // Move image 1 fully into scrollback.
        graphics.scroll(false, 0, 24, 4, true, 10);
        let mut lines: Vec<i32> = graphics.placements.iter().map(|p| p.line).collect();
        lines.sort_unstable();
        assert_eq!(lines, vec![-4, 0]);
        // d=a on the main screen removes only the visible placements, so the
        // scrollback one and the alternate-screen one both survive.
        graphics.handle(b"a=d,d=a", &main);
        let remaining: Vec<u32> = graphics.placements.iter().map(|p| p.image).collect();
        assert_eq!(remaining, vec![1, 2], "alt placement and scrollback survive");
        // Lowercase kept the named image's data.
        assert!(graphics.images.contains_key(&1) && graphics.images.contains_key(&2));
        // Clearing scrollback unplaces image 1; its named data still survives.
        graphics.delete_scrollback();
        assert_eq!(graphics.placements.len(), 1);
        assert!(graphics.images.contains_key(&1) && graphics.images.contains_key(&2));
        // Uppercase frees only images whose placements it removed; image 1 had none left on screen.
        graphics.handle(b"a=d,d=A", &main);
        assert!(graphics.images.contains_key(&2) && graphics.images.contains_key(&1));
        graphics.handle(b"a=d,d=I,i=1", &main);
        assert!(!graphics.images.contains_key(&1));
    }

    #[test]
    fn delete_with_i_or_n_placement_filter_and_pending_cancel() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        graphics.handle(format!("a=t,f=24,s=1,v=1,i=9,q=2;{pixel}").as_bytes(), &context());
        let at = |line: i32| Context { line, ..context() };
        graphics.handle(b"a=p,i=9,p=1,q=2", &at(1));
        graphics.handle(b"a=p,i=9,p=2,q=2", &at(2));
        graphics.handle(b"a=p,i=9,p=3,q=2", &at(3));
        // d=i with p= removes only that placement.
        graphics.handle(b"a=d,d=i,i=9,p=2", &context());
        assert_eq!(graphics.placements.len(), 2);
        assert!(graphics.placements.iter().all(|p| p.id != 2));
        // d=n via the number map removes the numbered image's placements, keeping data.
        graphics.handle(format!("a=t,f=24,s=1,v=1,I=3,q=2;{pixel}").as_bytes(), &context());
        graphics.handle(b"a=p,I=3,q=2", &at(4));
        let numbered = graphics.placements.iter().find(|p| p.line == 4).unwrap().image;
        graphics.handle(b"a=d,d=n,I=3", &context());
        assert!(!graphics.placements.iter().any(|p| p.image == numbered));
        assert!(graphics.images.contains_key(&numbered));
        // A delete also cancels an unfinished chunked upload.
        graphics.handle(b"a=t,f=24,s=2,v=2,i=11,m=1,q=2;AAAA", &context());
        graphics.handle(b"a=d,d=i,i=9", &context());
        assert!(graphics.handle(b"m=0;AAAA", &context()).reply.is_empty());
        assert!(!graphics.images.contains_key(&11));
    }

    #[test]
    fn idless_images_are_freed_by_lowercase_deletes() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        graphics.handle(format!("a=T,f=24,s=1,v=1,q=2,C=1;{pixel}").as_bytes(), &context());
        assert_eq!(graphics.images.len(), 1);
        graphics.handle(b"a=d,d=a", &context());
        assert!(graphics.placements.is_empty());
        assert!(graphics.images.is_empty() && graphics.bytes() == 0);
    }

    #[test]
    fn region_scrolls_move_only_region_placements_and_drop_leavers() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        let at = |line: i32| Context { line, alt: false, ..context() };
        for (id, line) in [(1u32, 0i32), (2, 4), (3, 7), (4, 10)] {
            graphics.handle(format!("a=t,f=24,s=1,v=1,i={id},q=2;{pixel}").as_bytes(), &at(line));
            graphics.handle(format!("a=p,i={id},q=2").as_bytes(), &at(line));
        }
        // Scroll the region [4, 10) up by 2: anchors 4 and 7 move, anchor 4
        // leaves the region and is deleted; 0 and 10 are outside.
        graphics.scroll(false, 4, 10, 2, false, 0);
        let lines: Vec<Option<i32>> = [1u32, 2, 3, 4]
            .map(|id| graphics.placements.iter().find(|p| p.image == id).map(|p| p.line))
            .into_iter()
            .collect();
        assert_eq!(lines, vec![Some(0), None, Some(5), Some(10)]);
        // Scrolling the same region down by 3 pushes the anchor at 5 out.
        graphics.scroll(false, 4, 10, -6, false, 0);
        let mut remaining: Vec<u32> = graphics.placements.iter().map(|p| p.image).collect();
        remaining.sort_unstable();
        assert_eq!(remaining, vec![1, 4]);
        assert_eq!(graphics.placements.iter().find(|p| p.image == 4).unwrap().line, 10);
    }

    #[test]
    fn delete_visible_scrollback_shift_and_reset_split_correctly() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        let main = Context { alt: false, ..context() };
        for id in 1..=3 {
            graphics.handle(format!("a=t,f=24,s=1,v=1,i={id},q=2;{pixel}").as_bytes(), &main);
        }
        let at = |line: i32| Context { line, alt: false, ..context() };
        graphics.handle(b"a=p,i=1,q=2", &at(0));
        graphics.handle(b"a=p,i=2,q=2", &at(-3));
        // A placement spanning scrollback into the viewport.
        graphics.handle(b"a=p,i=3,q=2,r=3", &at(-1));
        graphics.delete_scrollback();
        // Only image 2 lived entirely above the viewport.
        let images: Vec<u32> = graphics.placements.iter().map(|p| p.image).collect();
        assert_eq!(images, vec![1, 3]);
        graphics.delete_visible(false, 24);
        let images: Vec<u32> = graphics.placements.iter().map(|p| p.image).collect();
        assert!(images.is_empty(), "the spanning placement crossed line 0");
        // shift_main after a viewport clear drops placements out of history.
        graphics.handle(b"a=p,i=1,q=2", &at(2));
        graphics.shift_main(8, 5);
        assert!(graphics.placements.is_empty());
        graphics.reset();
        assert!(graphics.images.is_empty() && graphics.placements.is_empty() && graphics.bytes() == 0);
    }

    #[test]
    fn a_tall_image_scrolling_off_the_top_stays_until_its_last_row_is_gone() {
        let mut graphics = Graphics::default();
        // 8 pixels high in 16-pixel cells is one row; 64 pixels are four rows.
        let tall = encode(&[7u8; 8 * 64 * 3]);
        graphics.handle(format!("a=T,f=24,s=8,v=64,i=1,q=2,C=1;{tall}").as_bytes(), &context());
        assert_eq!(graphics.placements[0].rows, 4);
        for expected in [-1, -2, -3] {
            graphics.scroll(true, 0, 24, 1, false, 0);
            assert_eq!(graphics.placements[0].line, expected, "its lower rows are still on screen");
        }
        graphics.scroll(true, 0, 24, 1, false, 0);
        assert!(graphics.placements.is_empty());
        // A region that does not start at the top still drops an image whose anchor leaves it.
        graphics.handle(b"a=p,i=1,q=2,C=1", &Context { line: 5, ..context() });
        graphics.scroll(true, 5, 10, 1, false, 0);
        assert!(graphics.placements.is_empty());
    }

    #[test]
    fn uppercase_deletes_free_only_the_images_they_touch() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        // Images 1 and 2 are uploaded for a later a=p; image 3 is on screen.
        for id in [1, 2] {
            graphics.handle(format!("a=t,f=24,s=1,v=1,i={id},q=2;{pixel}").as_bytes(), &context());
        }
        graphics.handle(format!("a=T,f=24,s=1,v=1,i=3,q=2;{pixel}").as_bytes(), &context());
        graphics.handle(b"a=d,d=I,i=3,q=2", &context());
        assert!(!graphics.images.contains_key(&3));
        assert!(graphics.images.contains_key(&1) && graphics.images.contains_key(&2), "untouched uploads survive");
        graphics.handle(b"a=d,d=A,q=2", &context());
        assert_eq!(graphics.images.len(), 2, "d=A frees only images whose visible placements it removed");
        // d=I on an image that was never placed still frees it.
        graphics.handle(b"a=d,d=I,i=1,q=2", &context());
        assert_eq!(graphics.images.keys().copied().collect::<Vec<_>>(), vec![2]);
    }

    #[test]
    fn animation_frames_stop_at_the_documented_limit() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[255, 0, 0, 255]);
        graphics.handle(format!("a=T,f=32,s=1,v=1,i=1,q=2;{pixel}").as_bytes(), &context());
        // The transmission is frame 1; append exactly up to the total frame limit.
        for _ in 1..MAX_FRAMES {
            let outcome = graphics.handle(format!("a=f,i=1,q=1;{pixel}").as_bytes(), &context());
            assert!(outcome.reply.is_empty());
        }
        assert_eq!(graphics.images[&1].frame_count() as usize, MAX_FRAMES);
        let outcome = graphics.handle(format!("a=f,i=1,q=1;{pixel}").as_bytes(), &context());
        assert!(String::from_utf8_lossy(&outcome.reply).contains("ENOSPC"));
        assert_eq!(graphics.images[&1].frame_count() as usize, MAX_FRAMES);
    }

    #[test]
    fn animation_frames_compose_play_loop_and_park() {
        let mut graphics = Graphics::default();
        let red = encode(&[255, 0, 0, 255, 255, 0, 0, 255]);
        graphics.handle(format!("a=T,f=32,s=2,v=1,i=1,q=2;{red}").as_bytes(), &context());
        // Frame 2: frame 1 with its right pixel overwritten green; frame 3: half-transparent blue blended over frame 2.
        let reply = graphics.handle(format!("a=f,i=1,c=1,x=1,s=1,v=1,z=100,X=1;{}", encode(&[0, 255, 0, 255])).as_bytes(), &context());
        assert_eq!(reply.reply, b"\x1b_Gi=1;OK\x1b\\");
        graphics.handle(format!("a=f,i=1,c=2,s=1,v=1,z=100,q=2;{}", encode(&[0, 0, 255, 128])).as_bytes(), &context());
        let image = &graphics.images[&1];
        assert_eq!(image.frame_count(), 3);
        assert_eq!(image.frame(1), [255, 0, 0, 255, 0, 255, 0, 255]);
        assert_eq!(image.frame(2), [127, 0, 128, 255, 0, 255, 0, 255]);
        assert_eq!(image.rgba, image.frame(0), "frame 1 stays on display");
        // Frame 1 is gapless until a=a r=1 z= gives it a gap; nothing plays before s=3.
        graphics.handle(b"a=a,i=1,r=1,z=50", &context());
        let start = std::time::Instant::now();
        let at = |ms: u64| start + std::time::Duration::from_millis(ms);
        assert!(!graphics.tick(at(60)) && !graphics.animating());
        graphics.handle(b"a=a,i=1,s=3,v=1", &context());
        assert!(graphics.animating());
        let generation = graphics.images[&1].generation;
        assert!(!graphics.tick(at(0)), "the first tick only starts frame 1's gap");
        assert!(graphics.tick(at(50)));
        assert_eq!((graphics.images[&1].current(), graphics.images[&1].rgba.as_slice()), (1, graphics.images[&1].frame(1)));
        assert!(graphics.images[&1].generation > generation, "a new frame is a new generation for the renderer");
        assert!(!graphics.tick(at(100)));
        assert!(graphics.tick(at(150)));
        assert!(graphics.tick(at(250)) && graphics.images[&1].current() == 0, "an infinite loop wraps to frame 1");
        // v=2 plays one loop more and then parks on the last frame.
        graphics.handle(b"a=a,i=1,s=3,v=2", &context());
        for ms in [300, 400, 500, 600, 700] { graphics.tick(at(ms)); }
        assert_eq!(graphics.images[&1].current(), 2);
        assert!(!graphics.animating());
        // c= shows a frame directly; d=f deletes frames until the image is a still again.
        graphics.handle(b"a=a,i=1,c=1", &context());
        assert_eq!(graphics.images[&1].rgba, [255, 0, 0, 255, 255, 0, 0, 255]);
        let before = graphics.bytes();
        graphics.handle(b"a=d,d=f,i=1,r=2", &context());
        assert_eq!((graphics.images[&1].frame_count(), graphics.bytes()), (2, before - 8));
        graphics.handle(b"a=d,d=f,i=1,r=9", &context());
        assert_eq!((graphics.images[&1].frame_count(), graphics.bytes()), (1, 8));
        graphics.handle(b"a=d,d=F,i=1", &context());
        assert!(graphics.images.is_empty() && graphics.placements.is_empty());
    }

    #[test]
    fn deleting_root_frame_preserves_the_new_root_gap() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[255, 0, 0, 255]);
        graphics.handle(format!("a=T,f=32,s=1,v=1,i=1,q=2;{pixel}").as_bytes(), &context());
        for gap in [100, 200] {
            graphics.handle(format!("a=f,i=1,z={gap},q=2;{pixel}").as_bytes(), &context());
        }
        graphics.handle(b"a=a,i=1,r=1,z=50,s=3,v=1", &context());
        graphics.handle(b"a=d,d=f,i=1,r=1,q=2", &context());
        assert_eq!(graphics.images[&1].gap(0), 100);
        let start = std::time::Instant::now();
        assert!(!graphics.tick(start));
        assert!(!graphics.tick(start + std::time::Duration::from_millis(99)));
        assert!(graphics.tick(start + std::time::Duration::from_millis(100)));
    }

    #[test]
    fn frame_and_compose_commands_validate_their_targets() {
        let mut graphics = Graphics::default();
        let pixels = encode(&[1, 2, 3, 255, 4, 5, 6, 255]);
        graphics.handle(format!("a=t,f=32,s=2,v=1,i=2,q=2;{pixels}").as_bytes(), &context());
        let error = |graphics: &mut Graphics, keys: &str| String::from_utf8(graphics.handle(keys.as_bytes(), &context()).reply).unwrap();
        assert!(error(&mut graphics, &format!("a=f,i=9;{pixels}")).contains("ENOENT"));
        assert!(error(&mut graphics, &format!("a=f,i=2,s=3,v=1;{}", encode(&[0; 12]))).contains("EINVAL:frame larger"));
        assert!(error(&mut graphics, &format!("a=f,i=2,c=5;{pixels}")).contains("EINVAL:no such base frame"));
        assert!(error(&mut graphics, "a=c,i=2,r=1,c=2").contains("ENOENT:no such destination"));
        assert!(error(&mut graphics, "a=c,i=2,r=1,c=1").contains("overlap"));
        assert!(error(&mut graphics, "a=c,i=2,r=1,c=1,w=1,x=2").contains("out of bounds"));
        // Without frames a=c works on frame 1 itself: copy the left pixel over the right one.
        assert!(error(&mut graphics, "a=c,i=2,r=1,c=1,w=1,x=1,C=1").ends_with(";OK\x1b\\"));
        assert_eq!(graphics.images[&2].rgba, [1, 2, 3, 255, 1, 2, 3, 255]);
        // A chunked a=f continues across chunks that carry a=f, m and q only.
        let chunk = encode(&[9, 9, 9, 255, 9, 9, 9, 255]);
        let (head, tail) = chunk.split_at(4);
        assert!(graphics.handle(format!("a=f,i=2,q=2,m=1;{head}").as_bytes(), &context()).reply.is_empty());
        graphics.handle(format!("a=f,m=0;{tail}").as_bytes(), &context());
        assert_eq!(graphics.images[&2].frame(1), [9, 9, 9, 255, 9, 9, 9, 255]);
    }

    #[test]
    fn relative_parents_are_resolved_only_on_the_childs_screen() {
        for alt in [false, true] {
            let mut graphics = Graphics::default();
            let pixel = encode(&[1, 2, 3]);
            let source = Context { alt: !alt, line: 2, col: 3, ..context() };
            let target = Context { alt, line: 8, col: 9, ..context() };
            for id in [1, 2] { graphics.handle(format!("a=t,f=24,s=1,v=1,i={id},q=2;{pixel}").as_bytes(), &source); }
            graphics.handle(b"a=p,i=1,p=1,q=2", &source);
            let rejected = graphics.handle(b"a=p,i=2,p=2,P=1,Q=1", &target);
            assert!(String::from_utf8(rejected.reply).unwrap().contains("ENOPARENT"));
            // Identical placement ids on different screens are separate anchors.
            graphics.handle(b"a=p,i=1,p=1,q=2", &target);
            graphics.handle(b"a=p,i=2,p=2,P=1,Q=1,H=1,V=1,q=2", &target);
            let child = graphics.drawn(alt).into_iter().find(|p| p.image == 2).unwrap();
            assert_eq!((child.line, child.col), (9, 10));
            graphics.handle(b"a=d,d=i,i=1", &source);
            assert!(graphics.drawn(alt).iter().any(|p| p.image == 2), "deleting the other screen's parent must preserve this child");
            graphics.handle(b"a=d,d=i,i=1", &target);
            assert!(graphics.drawn(alt).is_empty());
        }
    }

    #[test]
    fn relative_placements_follow_their_parent_and_go_with_it() {
        let mut graphics = Graphics::default();
        let pixel = encode(&[1, 2, 3]);
        for id in [1, 2] { graphics.handle(format!("a=t,f=24,s=1,v=1,i={id},q=2;{pixel}").as_bytes(), &context()); }
        graphics.handle(b"a=p,i=1,p=1,q=2", &Context { line: 3, col: 4, ..context() });
        let child = graphics.handle(b"a=p,i=2,p=5,P=1,Q=1,H=2,V=-1,q=2", &Context { line: 9, col: 9, ..context() });
        assert!(child.advance.is_none(), "relative placements never move the cursor");
        let anchors = |graphics: &Graphics| graphics.drawn(true).iter().map(|p| (p.image, p.line, p.col)).collect::<Vec<_>>();
        assert_eq!(anchors(&graphics), [(1, 3, 4), (2, 2, 6)]);
        let reply = |graphics: &mut Graphics, keys: &[u8]| String::from_utf8(graphics.handle(keys, &context()).reply).unwrap();
        assert!(reply(&mut graphics, b"a=p,i=2,p=6,P=1,Q=9").contains("ENOPARENT"));
        assert!(reply(&mut graphics, b"a=p,i=1,p=1,P=2,Q=5").contains("ECYCLE"));
        // A scroll moves the parent; the child keeps its offset and is not moved twice.
        graphics.scroll(true, 0, 24, 1, false, 0);
        assert_eq!(anchors(&graphics), [(1, 2, 4), (2, 1, 6)]);
        // Position deletes see the child where it is drawn; deleting the parent takes the child along.
        graphics.handle(b"a=d,d=p,x=7,y=2", &context());
        assert_eq!(anchors(&graphics), [(1, 2, 4)]);
        graphics.handle(b"a=p,i=2,p=5,P=1,Q=1,H=2,V=-1,q=2", &context());
        graphics.handle(b"a=d,d=i,i=1", &context());
        assert!(graphics.placements.is_empty(), "children of a deleted parent are removed");
        // Chains are bounded.
        graphics.handle(b"a=p,i=1,p=1,q=2", &context());
        for link in 2..=MAX_CHAIN as u32 + 1 {
            graphics.handle(format!("a=p,i=1,p={link},P=1,Q={},H=1,q=2", link - 1).as_bytes(), &context());
        }
        let deep = format!("a=p,i=2,p=1,P=1,Q={}", MAX_CHAIN + 1);
        assert!(reply(&mut graphics, deep.as_bytes()).contains("ETOODEEP"));
    }

    #[test]
    fn virtual_placements_are_found_but_never_drawn_moved_or_hit_by_position() {
        let mut graphics = Graphics::default();
        graphics.handle(format!("a=t,f=24,s=1,v=1,i=4,q=2;{}", encode(&[1, 2, 3])).as_bytes(), &context());
        let outcome = graphics.handle(b"a=p,U=1,i=4,p=7,c=4,r=2,q=2", &Context { line: 2, ..context() });
        assert!(outcome.advance.is_none());
        assert!(graphics.drawn(true).is_empty());
        assert_eq!(graphics.virtual_placement(4, 7, context().alt).map(|p| (p.cols, p.rows)), Some((4, 2)));
        assert_eq!(graphics.virtual_placement(4, 0, context().alt).map(|p| p.id), Some(7));
        assert!(graphics.virtual_placement(4, 8, context().alt).is_none());
        graphics.scroll(true, 0, 24, 5, false, 0);
        graphics.delete_visible(true, 24);
        graphics.handle(b"a=d,d=a", &context());
        graphics.handle(b"a=d,d=y,y=3", &context());
        assert_eq!(graphics.virtual_placement(4, 7, context().alt).map(|p| p.line), Some(2), "untouched by scrolls and clears");
        graphics.handle(b"a=d,d=i,i=4", &context());
        assert!(graphics.virtual_placement(4, 7, context().alt).is_none());
    }

    #[test]
    fn temp_file_transmission_reads_and_deletes_and_queries_read_nothing() {
        let mut graphics = Graphics::default();
        let path = std::env::temp_dir().join(format!("tty-graphics-protocol-akitty-graphics-{}.rgb", std::process::id()));
        std::fs::write(&path, [1u8, 2, 3, 4, 5, 6]).unwrap();
        let name = encode(path.as_os_str().as_encoded_bytes());
        let outcome = graphics.handle(format!("a=T,t=t,f=24,s=2,v=1,i=6;{name}").as_bytes(), &context());
        assert_eq!(outcome.reply, b"\x1b_Gi=6;OK\x1b\\");
        assert_eq!(graphics.images[&6].rgba, [1, 2, 3, 255, 4, 5, 6, 255]);
        assert!(!path.exists(), "the terminal deletes temp files it read");
        // Kitten icat probes each medium with a real one-pixel object; the probe reads it and consumes a temp file.
        let query = |graphics: &mut Graphics, medium: char, name: &str| {
            String::from_utf8(graphics.handle(format!("a=q,i=31,t={medium},f=24,s=1,v=1;{}", encode(name.as_bytes())).as_bytes(), &context()).reply).unwrap()
        };
        let probe = std::env::temp_dir().join(format!("tty-graphics-protocol-akitty-probe-{}", std::process::id()));
        std::fs::write(&probe, [1u8, 2, 3]).unwrap();
        assert!(query(&mut graphics, 't', probe.to_str().unwrap()).ends_with(";OK\x1b\\"));
        assert!(!probe.exists(), "a temp-file probe is consumed");
        std::fs::write(&probe, [1u8, 2, 3]).unwrap();
        assert!(query(&mut graphics, 'f', probe.to_str().unwrap()).ends_with(";OK\x1b\\"));
        assert!(probe.exists(), "a file probe is not");
        std::fs::remove_file(&probe).unwrap();
        assert!(query(&mut graphics, 'f', "/dev/zero").contains("EBADF"));
        assert!(query(&mut graphics, 'x', "/dev/zero").contains("ENOTSUP"));
        let missing = encode(b"/tmp/tty-graphics-protocol-missing");
        // A failed read reports one fixed message, never the path.
        let reply = graphics.handle(format!("a=T,t=t,f=24,s=2,v=1,i=7;{missing}").as_bytes(), &context()).reply;
        assert_eq!(reply, b"\x1b_Gi=7;EBADF:failed to read image data\x1b\\");
    }
}
