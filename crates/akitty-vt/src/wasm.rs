//! WASM ABI 1. Hosts allocate byte buffers with `akitty_vt_alloc` and release them
//! with the original length. All terminal IDs are opaque and never reused.
//!
//! A cell is eight little-endian u32 values: scalar, foreground, background,
//! attributes, underline color (0xffffffff means default), column width,
//! hyperlink identity, and additional scalar count.
//! Attributes use cell:: constants in bits 0..6 and underline style in bits 8..10.
//! Row indices are screen-relative; negative indices address scrollback.

use crate::{Event, Terminal};
use std::cell::RefCell;
use std::collections::{BTreeMap, VecDeque};

const MAX_BUFFER: usize = 32 * 1024 * 1024;
const MAX_REPLIES: usize = 65536;

enum HostEvent {
    Title(String),
    Bell(u32),
}
struct Instance {
    terminal: Terminal,
    replies: VecDeque<u8>,
    bells: u32,
    reply_overflow: bool,
    events: VecDeque<HostEvent>,
    clean_revision: Option<u64>,
    clean_rows: Vec<u64>,
}
impl Instance {
    fn event(&mut self, event: Event) {
        match event {
            Event::Reply(bytes) => {
                if self.reply_overflow {
                    return;
                }
                if self.replies.len() + bytes.len() > MAX_REPLIES {
                    self.replies
                        .extend(bytes.into_iter().take(MAX_REPLIES - self.replies.len()));
                    self.reply_overflow = true;
                } else {
                    self.replies.extend(bytes);
                }
            }
            Event::Bell => {
                self.bells = self.bells.saturating_add(1);
                if let Some(HostEvent::Bell(count)) = self.events.back_mut() {
                    *count = count.saturating_add(1);
                } else {
                    self.events.push_back(HostEvent::Bell(1));
                }
            }
            Event::Title(title) => self.events.push_back(HostEvent::Title(title)),
            _ => {}
        }
        while self.events.len() > 4096 {
            self.events.pop_front();
        }
    }
}
#[derive(Default)]
struct Registry {
    next: u32,
    terminals: BTreeMap<u32, Instance>,
    buffers: BTreeMap<usize, Box<[u8]>>,
    buffer_bytes: usize,
}
thread_local! { static REGISTRY: RefCell<Registry> = RefCell::new(Registry::default()); }

fn read_buffer<R>(pointer: u32, length: u32, callback: impl FnOnce(&[u8]) -> R) -> Option<R> {
    REGISTRY.with(|registry| {
        let registry = registry.borrow();
        let buffer = registry.buffers.get(&(pointer as usize))?;
        buffer.get(..length as usize).map(callback)
    })
}
fn output(pointer: u32, capacity: u32, bytes: &[u8]) -> u32 {
    REGISTRY.with(|registry| {
        let mut registry = registry.borrow_mut();
        let Some(buffer) = registry.buffers.get_mut(&(pointer as usize)) else {
            return 0;
        };
        if capacity as usize > buffer.len() || bytes.len() > capacity as usize {
            return 0;
        }
        buffer[..bytes.len()].copy_from_slice(bytes);
        bytes.len() as u32
    })
}
fn inspect<R: Default>(id: u32, callback: impl FnOnce(&Instance) -> R) -> R {
    REGISTRY.with(|registry| {
        registry
            .borrow()
            .terminals
            .get(&id)
            .map(callback)
            .unwrap_or_default()
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_abi_version() -> u32 {
    1
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_unicode_version() -> u32 {
    let (major, minor, patch) = unicode_width::UNICODE_VERSION;
    u32::from(major) << 16 | u32::from(minor) << 8 | u32::from(patch)
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_deadline(id: u32) -> f64 {
    inspect(id, |instance| {
        instance
            .terminal
            .sync_deadline()
            .map_or(-1.0, |ms| ms as f64)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_alloc(length: u32) -> u32 {
    if length == 0 || length as usize > MAX_BUFFER {
        return 0;
    }
    REGISTRY.with(|registry| {
        let mut registry = registry.borrow_mut();
        if registry.buffer_bytes + length as usize > 64 * 1024 * 1024 {
            return 0;
        }
        let mut bytes = vec![0u8; length as usize].into_boxed_slice();
        let pointer = bytes.as_mut_ptr() as usize;
        registry.buffer_bytes += bytes.len();
        registry.buffers.insert(pointer, bytes);
        pointer as u32
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_free(pointer: u32, length: u32) -> u32 {
    REGISTRY.with(|registry| {
        let mut registry = registry.borrow_mut();
        if registry
            .buffers
            .get(&(pointer as usize))
            .is_none_or(|buffer| buffer.len() != length as usize)
        {
            return 0;
        }
        registry.buffers.remove(&(pointer as usize));
        registry.buffer_bytes -= length as usize;
        1
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_create(cols: u32, rows: u32, history: u32) -> u32 {
    REGISTRY.with(|registry| {
        let mut registry = registry.borrow_mut();
        if registry.terminals.len() >= 64 {
            return 0;
        }
        let Ok(mut terminal) = Terminal::new(cols as usize, rows as usize, history as usize) else {
            return 0;
        };
        terminal.enable_grapheme_support(true);
        terminal.preserve_erased_screen = false;
        terminal.title_max_bytes = 4094;
        terminal.title_max_chars = 4096;
        let Some(id) = registry.next.checked_add(1) else {
            return 0;
        };
        registry.next = id;
        registry.terminals.insert(
            id,
            Instance {
                terminal,
                replies: VecDeque::new(),
                bells: 0,
                reply_overflow: false,
                clean_revision: None,
                clean_rows: Vec::new(),
                events: VecDeque::new(),
            },
        );
        id
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_destroy(id: u32) -> u32 {
    REGISTRY.with(|registry| u32::from(registry.borrow_mut().terminals.remove(&id).is_some()))
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_write(id: u32, pointer: u32, length: u32, now_ms: f64) -> u32 {
    if !now_ms.is_finite() || now_ms < 0.0 {
        return 0;
    }
    REGISTRY.with(|registry| {
        let mut registry = registry.borrow_mut();
        let Registry {
            terminals, buffers, ..
        } = &mut *registry;
        let Some(bytes) = buffers
            .get(&(pointer as usize))
            .and_then(|buffer| buffer.get(..length as usize))
        else {
            return 0;
        };
        let Some(instance) = terminals.get_mut(&id) else {
            return 0;
        };
        for chunk in bytes.chunks(8192) {
            let mut events = Vec::new();
            instance.terminal.feed(chunk, now_ms as u64, |event| {
                if matches!(event, Event::Reply(_) | Event::Title(_) | Event::Bell) {
                    events.push(event);
                }
            });
            for event in events {
                instance.event(event);
            }
        }
        1
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_tick(id: u32, now_ms: f64) -> u32 {
    if !now_ms.is_finite() || now_ms < 0.0 {
        return 0;
    }
    REGISTRY.with(|registry| {
        let mut registry = registry.borrow_mut();
        let Some(instance) = registry.terminals.get_mut(&id) else {
            return 0;
        };
        let mut events = Vec::new();
        let changed = instance
            .terminal
            .expire_sync(now_ms as u64, |event| events.push(event));
        for event in events {
            instance.event(event);
        }
        u32::from(changed)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_resize(id: u32, cols: u32, rows: u32) -> u32 {
    REGISTRY.with(|registry| {
        let mut registry = registry.borrow_mut();
        let Some(instance) = registry.terminals.get_mut(&id) else {
            return 0;
        };
        u32::from(
            instance
                .terminal
                .resize(cols as usize, rows as usize, |_| {})
                .is_ok(),
        )
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_get(id: u32, field: u32) -> u32 {
    inspect(id, |instance| {
        let term = &instance.terminal;
        match field {
            0 => term.cols() as u32,
            1 => term.rows() as u32,
            2 => term.cursor().col as u32,
            3 => term.cursor().row as u32,
            4 => u32::from(term.modes.cursor_visible),
            5 => u32::from(term.modes.alternate),
            6 => term.screen().history.len() as u32,
            7 => term.revision as u32,
            8 => u32::from(term.keyboard_flags()),
            18 => term.palette.cursor().unwrap_or(u32::MAX),
            9 => term.palette.resolve(crate::cell::Color::Foreground),
            10 => term.palette.resolve(crate::cell::Color::Background),
            11 => instance.replies.len() as u32,
            12 => u32::from(instance.reply_overflow),
            13 => instance.bells,
            14 => u32::from(instance.clean_revision != Some(term.revision)),
            15 => u32::from(term.modes.cursor_shape),
            16 => u32::from(term.modes.cursor_blink),
            17 => instance.events.len() as u32,
            _ => 0,
        }
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_mode(id: u32, mode: u32, ansi: u32) -> u32 {
    inspect(id, |instance| {
        if mode > u32::from(u16::MAX) {
            0
        } else {
            u32::from(
                instance
                    .terminal
                    .mode(mode as u16, ansi != 0)
                    .unwrap_or(false),
            )
        }
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_line(id: u32, row: i32, pointer: u32, capacity: u32) -> u32 {
    let bytes: Vec<u8> = inspect(id, |instance| {
        let Some(line) = instance.terminal.screen().line(row) else {
            return Vec::new();
        };
        let mut bytes = Vec::with_capacity(line.cells.len() * 32);
        append_cells(
            &instance.terminal.palette,
            &line.cells,
            &mut bytes,
            instance.terminal.modes.reverse_video,
        );
        bytes
    });
    output(pointer, capacity, &bytes)
}
/// Select a retained screen explicitly: 0 normal, 1 alternate. All buffer APIs
/// are read-only and never switch modes, consume events or alter display offset.
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_buffer_get(id: u32, alternate: u32, field: u32) -> u32 {
    if alternate > 1 {
        return 0;
    }
    inspect(id, |instance| {
        let screen = instance.terminal.screen_for(alternate != 0);
        match field {
            0 => screen.cols as u32,
            1 => screen.rows.len() as u32,
            2 => screen.cursor.position.col as u32,
            3 => screen.cursor.position.row as u32,
            6 => screen.history.len() as u32,
            _ => 0,
        }
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_buffer_line(
    id: u32,
    alternate: u32,
    row: i32,
    pointer: u32,
    capacity: u32,
) -> u32 {
    if alternate > 1 {
        return 0;
    }
    let bytes: Vec<u8> = inspect(id, |instance| {
        let term = &instance.terminal;
        let Some(line) = term.screen_for(alternate != 0).line(row) else {
            return Vec::new();
        };
        let mut bytes = Vec::with_capacity(line.cells.len() * 32);
        append_cells(
            &term.palette,
            &line.cells,
            &mut bytes,
            term.modes.reverse_video,
        );
        bytes
    });
    output(pointer, capacity, &bytes)
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_buffer_wrapped(id: u32, alternate: u32, row: i32) -> u32 {
    if alternate > 1 {
        return 0;
    }
    inspect(id, |instance| {
        u32::from(
            instance
                .terminal
                .screen_for(alternate != 0)
                .line(row.saturating_sub(1))
                .is_some_and(|line| line.wrapped),
        )
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_buffer_text(
    id: u32,
    alternate: u32,
    row: i32,
    col: u32,
    pointer: u32,
    capacity: u32,
) -> u32 {
    if alternate > 1 {
        return 0;
    }
    let text: String = inspect(id, |instance| {
        instance
            .terminal
            .screen_for(alternate != 0)
            .line(row)
            .and_then(|line| line.cells.get(col as usize))
            .map_or(String::new(), |cell| cell.text())
    });
    output(pointer, capacity, text.as_bytes())
}
fn append_cells(
    palette: &crate::cell::Palette,
    cells: &[crate::cell::Cell],
    bytes: &mut Vec<u8>,
    reverse: bool,
) {
    for cell in cells {
        let flags = u32::from(cell.style.attrs ^ if reverse { crate::cell::INVERSE } else { 0 })
            | u32::from(cell.style.underline) << 8;
        for word in [
            if cell.written { u32::from(cell.ch) } else { 0 },
            palette.resolve(cell.style.fg),
            palette.resolve(cell.style.bg),
            flags,
            cell.style
                .underline_color
                .map_or(u32::MAX, |c| palette.resolve(c)),
            u32::from(cell.width),
            cell.link_id,
            cell.combining.len() as u32,
        ] {
            bytes.extend_from_slice(&word.to_le_bytes());
        }
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_viewport(id: u32, pointer: u32, capacity: u32) -> u32 {
    let bytes: Vec<u8> = inspect(id, |instance| {
        let term = &instance.terminal;
        let mut bytes = Vec::with_capacity(term.cols() * term.rows() * 32);
        for row in &term.screen().rows {
            append_cells(
                &term.palette,
                &row.cells,
                &mut bytes,
                term.modes.reverse_video,
            );
        }
        bytes
    });
    output(pointer, capacity, &bytes)
}
fn row_hash(term: &Terminal, row: usize) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    let mut mix = |word: u64| {
        hash = (hash ^ word).wrapping_mul(0x100000001b3);
    };
    mix(u64::from(term.modes.reverse_video));
    mix(term.screen().rows[row].generation);
    for cell in &term.screen().rows[row].cells {
        mix(u64::from(cell.ch));
        mix(u64::from(cell.width));
        mix(u64::from(cell.style.attrs));
        mix(u64::from(cell.style.underline));
        mix(u64::from(term.palette.resolve(cell.style.fg)));
        mix(u64::from(term.palette.resolve(cell.style.bg)));
        mix(u64::from(cell.link_id));
        mix(cell
            .style
            .underline_color
            .map_or(u64::MAX, |c| u64::from(term.palette.resolve(c))));
        for ch in &cell.combining {
            mix(u64::from(*ch));
        }
    }
    hash
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_dirty(id: u32, row: u32) -> u32 {
    inspect(id, |instance| {
        let row = row as usize;
        if row >= instance.terminal.rows() {
            return 0;
        }
        u32::from(instance.clean_rows.get(row).copied() != Some(row_hash(&instance.terminal, row)))
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_clean(id: u32) {
    REGISTRY.with(|registry| {
        if let Some(instance) = registry.borrow_mut().terminals.get_mut(&id) {
            instance.clean_rows.resize(instance.terminal.rows(), 0);
            for row in 0..instance.terminal.rows() {
                instance.clean_rows[row] = row_hash(&instance.terminal, row);
            }
            instance.clean_revision = Some(instance.terminal.revision);
        }
    });
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_color(id: u32, index: u32, rgb: u32) -> u32 {
    REGISTRY.with(|registry| {
        let mut registry = registry.borrow_mut();
        let Some(instance) = registry.terminals.get_mut(&id) else {
            return 0;
        };
        if index > 258 {
            return 0;
        }
        instance
            .terminal
            .palette
            .configure(index as usize, rgb & 0xffffff);
        instance.terminal.revision = instance.terminal.revision.wrapping_add(1);
        1
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_wrapped(id: u32, row: i32) -> u32 {
    inspect(id, |instance| {
        u32::from(
            instance
                .terminal
                .screen()
                .line(row.saturating_sub(1))
                .is_some_and(|line| line.wrapped),
        )
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_text(
    id: u32,
    row: i32,
    col: u32,
    kind: u32,
    pointer: u32,
    capacity: u32,
) -> u32 {
    let text: String = inspect(id, |instance| {
        if kind == 2 {
            return instance.terminal.title.clone();
        }
        let Some(cell) = instance
            .terminal
            .screen()
            .line(row)
            .and_then(|line| line.cells.get(col as usize))
        else {
            return String::new();
        };
        if kind == 1 {
            cell.link
                .as_ref()
                .map_or(String::new(), |link| link.to_string())
        } else {
            cell.text()
        }
    });
    output(pointer, capacity, text.as_bytes())
}
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_replies(id: u32, pointer: u32, capacity: u32) -> u32 {
    let bytes: Vec<u8> = inspect(id, |instance| {
        instance
            .replies
            .iter()
            .copied()
            .take(capacity as usize)
            .collect()
    });
    let copied = output(pointer, capacity, &bytes);
    if copied != 0 {
        REGISTRY.with(|registry| {
            if let Some(instance) = registry.borrow_mut().terminals.get_mut(&id) {
                instance.replies.drain(..copied as usize);
                if instance.replies.is_empty() {
                    instance.reply_overflow = false;
                }
            }
        });
    }
    copied
}
/// One host event: byte tag (1 title, 2 bell), followed by title UTF-8 or a
/// little-endian bell count. Delivery is committed only after the copy succeeds.
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_event(id: u32, pointer: u32, capacity: u32) -> u32 {
    let bytes: Vec<u8> = inspect(id, |instance| match instance.events.front() {
        Some(HostEvent::Title(title)) => {
            let mut bytes = vec![1];
            bytes.extend_from_slice(title.as_bytes());
            bytes
        }
        Some(HostEvent::Bell(count)) => {
            let mut bytes = vec![2];
            bytes.extend_from_slice(&count.to_le_bytes());
            bytes
        }
        None => Vec::new(),
    });
    let count = output(pointer, capacity, &bytes);
    if count != 0 {
        REGISTRY.with(|registry| {
            if let Some(instance) = registry.borrow_mut().terminals.get_mut(&id) {
                instance.events.pop_front();
            }
        });
    }
    count
}

/// Key options pack Kitty flags in bits 0..4, application cursor/keypad in bits
/// 8/9, Alt escape prefix in bit 10 and modifyOtherKeys=2 in bit 11.
/// Event action is 1 press, 2 repeat, 3 release; modifiers use protocol bits.
#[unsafe(no_mangle)]
pub extern "C" fn akitty_vt_key(
    code: u32,
    shifted: u32,
    base: u32,
    modifiers: u32,
    action: u32,
    options: u32,
    text_pointer: u32,
    text_length: u32,
    out_pointer: u32,
    out_capacity: u32,
) -> u32 {
    let Some(text) = read_buffer(text_pointer, text_length, |bytes| {
        std::str::from_utf8(bytes).ok().map(str::to_owned)
    })
    .flatten() else {
        return 0;
    };
    let action = match action {
        1 => crate::key::Action::Press,
        2 => crate::key::Action::Repeat,
        3 => crate::key::Action::Release,
        _ => return 0,
    };
    let key = crate::key::Key {
        code,
        shifted: (shifted != 0).then_some(shifted),
        base_layout: (base != 0).then_some(base),
        modifiers: modifiers as u8,
        action,
        text: &text,
        composing: false,
    };
    let options = crate::key::Options {
        kitty_flags: (options & 31) as u8,
        app_cursor: options & (1 << 8) != 0,
        app_keypad: options & (1 << 9) != 0,
        alt_escape: options & (1 << 10) != 0,
        modify_other_keys: if options & (1 << 11) != 0 { 2 } else { 0 },
    };
    output(
        out_pointer,
        out_capacity,
        &crate::key::encode(&key, options),
    )
}
