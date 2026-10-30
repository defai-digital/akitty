//! Akitty's versioned, macOS-only terminal boundary.
#![deny(unsafe_op_in_unsafe_fn)]
#[cfg(not(target_os = "macos"))]
compile_error!("Akitty supports macOS only");

mod child;
mod chrome;
mod graphics;
mod media;
mod model;
mod placeholder;
mod session;
mod tracker;

use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, OnceLock};

pub const ABI_VERSION: u32 = 1;
const MAX_REQUEST: usize = 1_048_576;
const MAX_RESPONSE: usize = 8 * 1_048_576;

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Version {},
    Create {
        cols: usize,
        rows: usize,
        shell: Option<String>,
        cwd: Option<String>,
        headless: Option<bool>,
        scrollback: Option<usize>,
    },
    Close {
        id: u64,
    },
    Snapshot {
        id: u64,
        since: Option<u64>,
    },
    Input {
        id: u64,
        text: String,
        paste: Option<bool>,
    },
    InputBytes { id: u64, bytes: Vec<u8> },
    Feed {
        id: u64,
        text: String,
    },
    Resize {
        id: u64,
        cols: usize,
        rows: usize,
    },
    Scroll {
        id: u64,
        lines: i32,
    },
    /// Pixel size of one cell, used for graphics placement and size reports.
    CellSize {
        id: u64,
        width: u32,
        height: u32,
    },
    Select {
        id: u64,
        start_row: usize,
        start_col: usize,
        end_row: usize,
        end_col: usize,
    },
    Find {
        id: u64,
        text: String,
    },
    /// Replace the session chrome document. `clear` removes it. This entry
    /// applies even when program chrome is off.
    Chrome {
        id: u64,
        #[serde(default)]
        clear: bool,
        status: Option<chrome::StatusInput>,
        mark: Option<chrome::MarkInput>,
        progress: Option<chrome::ProgressInput>,
        sprite: Option<Box<chrome::SpriteInput>>,
    },
    /// When `enabled` is false, `OSC 771` no longer changes the document.
    ProgramChrome { id: u64, enabled: bool },
}

#[derive(Default)]
struct Registry {
    next_id: u64,
    /// Sessions being spawned outside the lock; they count against the cap.
    creating: usize,
    sessions: HashMap<u64, Arc<session::Session>>,
}
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();

/// Response data: a value, or JSON a hot path (snapshots) already serialized.
enum Reply {
    Value(Value),
    Json(String),
}

/// Runs one request, turning a panic into an error response.
fn guarded(bytes: &[u8]) -> Result<Reply, String> {
    catch_unwind(AssertUnwindSafe(|| dispatch(bytes)))
        .unwrap_or_else(|_| Err("internal panic; recreate affected session".into()))
}

fn envelope(result: Result<Value, String>) -> Value {
    match result {
        Ok(data) => json!({"version": ABI_VERSION, "ok": true, "data": data}),
        Err(error) => json!({"version": ABI_VERSION, "ok": false, "error": error}),
    }
}

/// The response envelope as a value. The C ABI uses [`respond`], which splices
/// pre-serialized data instead of parsing it back.
pub fn request(bytes: &[u8]) -> Value {
    envelope(guarded(bytes).and_then(|reply| match reply {
        Reply::Value(value) => Ok(value),
        Reply::Json(json) => serde_json::from_str(&json).map_err(|e| e.to_string()),
    }))
}

/// The serialized response envelope for one request.
fn respond(bytes: &[u8]) -> Vec<u8> {
    let result = match guarded(bytes) {
        Ok(Reply::Json(json)) => return format!(r#"{{"version":{ABI_VERSION},"ok":true,"data":{json}}}"#).into_bytes(),
        Ok(Reply::Value(value)) => Ok(value),
        Err(error) => Err(error),
    };
    serde_json::to_vec(&envelope(result)).unwrap_or_default()
}

fn dispatch(bytes: &[u8]) -> Result<Reply, String> {
    if bytes.len() > MAX_REQUEST {
        return Err("request exceeds 1 MiB".into());
    }
    let request: Request = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    let mut registry = REGISTRY
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let value = match request {
        Request::Version {} => Ok(
            json!({"abi": ABI_VERSION, "schema": 1, "platform": "macos", "engine": "alacritty_terminal 0.26.0"}),
        ),
        Request::Create {
            cols,
            rows,
            shell,
            cwd,
            headless,
            scrollback,
        } => {
            model::Size::validate(cols, rows)?;
            if registry.sessions.len() + registry.creating >= 64 {
                return Err("session limit reached".into());
            }
            registry.next_id = registry
                .next_id
                .checked_add(1)
                .ok_or("session ID exhausted")?;
            let id = registry.next_id;
            registry.creating += 1;
            drop(registry);
            let created = session::Session::new(
                cols,
                rows,
                shell,
                cwd,
                headless.unwrap_or(false),
                scrollback.unwrap_or(5000),
            );
            let mut registry = REGISTRY
                .get()
                .unwrap()
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            registry.creating -= 1;
            let session = Arc::new(created?);
            registry.sessions.insert(id, session);
            Ok(json!({"id": id}))
        }
        Request::Close { id } => {
            let session = registry.sessions.remove(&id);
            drop(registry);
            if let Some(session) = session {
                session.close()?;
            }
            Ok(json!({}))
        }
        request => {
            let id = match &request {
                Request::Snapshot { id, .. }
                | Request::Input { id, .. }
                | Request::InputBytes { id, .. }
                | Request::Feed { id, .. }
                | Request::Resize { id, .. }
                | Request::Scroll { id, .. }
                | Request::CellSize { id, .. }
                | Request::Select { id, .. }
                | Request::Find { id, .. }
                | Request::Chrome { id, .. }
                | Request::ProgramChrome { id, .. } => *id,
                _ => unreachable!(),
            };
            let session = registry
                .sessions
                .get(&id)
                .cloned()
                .ok_or("unknown or closed session")?;
            drop(registry);
            match request {
                Request::Snapshot { since, .. } => return session.snapshot(since).map(Reply::Json),
                Request::Input { text, paste, .. } => {
                    session.input(text, paste.unwrap_or(false))?;
                    Ok(json!({}))
                }
                Request::InputBytes { bytes, .. } => { session.input_bytes(bytes)?; Ok(json!({})) }
                Request::Feed { text, .. } => {
                    session.feed(text.as_bytes())?;
                    Ok(json!({}))
                }
                Request::Resize { cols, rows, .. } => {
                    session.resize(cols, rows)?;
                    Ok(json!({}))
                }
                Request::Scroll { lines, .. } => {
                    session.scroll(lines)?;
                    Ok(json!({}))
                }
                Request::CellSize { width, height, .. } => {
                    session.set_cell_size(width, height)?;
                    Ok(json!({}))
                }
                Request::Select {
                    start_row,
                    start_col,
                    end_row,
                    end_col,
                    ..
                } => session.select(start_row, start_col, end_row, end_col),
                Request::Find { text, .. } => session.find(&text),
                Request::Chrome { clear, status, mark, progress, sprite, .. } => {
                    session.set_chrome(chrome::ChromeInput { clear, status, mark, progress, sprite: sprite.map(|value| *value) })?;
                    Ok(json!({}))
                }
                Request::ProgramChrome { enabled, .. } => {
                    session.set_program_chrome(enabled)?;
                    Ok(json!({}))
                }
                _ => unreachable!(),
            }
        }
    };
    value.map(Reply::Value)
}

#[repr(C)]
pub struct AkittyBuffer {
    pub data: *mut u8,
    pub len: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn akitty_abi_version() -> u32 {
    ABI_VERSION
}

/// # Safety
/// `data` must reference `len` readable bytes for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn akitty_request_v1(data: *const u8, len: usize) -> AkittyBuffer {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let mut bytes = if len > MAX_REQUEST || data.is_null() {
            br#"{"version":1,"ok":false,"error":"invalid request buffer"}"#.to_vec()
        } else {
            // SAFETY: caller supplies a live byte slice; the bound is checked above.
            respond(unsafe { std::slice::from_raw_parts(data, len) })
        };
        if bytes.len() > MAX_RESPONSE {
            bytes = br#"{"version":1,"ok":false,"error":"snapshot exceeds 8 MiB"}"#.to_vec();
        }
        let bytes = bytes.into_boxed_slice();
        let len = bytes.len();
        AkittyBuffer {
            data: Box::into_raw(bytes).cast::<u8>(),
            len,
        }
    }));
    result.unwrap_or(AkittyBuffer {
        data: std::ptr::null_mut(),
        len: 0,
    })
}

/// Copies the RGBA pixels of a stored Kitty graphics image (width * height * 4
/// bytes, row-major, straight alpha) into `out`. Returns the byte count, or 0 when
/// the session or image is unknown, the image was replaced by a larger one, or
/// `capacity` is too small. This avoids pushing megabytes through the JSON limit.
///
/// # Safety
/// `out` must reference `capacity` writable bytes for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn akitty_image_read_v1(session: u64, image: u32, out: *mut u8, capacity: usize) -> usize {
    catch_unwind(AssertUnwindSafe(|| {
        if out.is_null() || capacity == 0 {
            return 0;
        }
        let Some(registry) = REGISTRY.get() else { return 0 };
        let found = registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .sessions
            .get(&session)
            .cloned();
        let Some(found) = found else { return 0 };
        // SAFETY: the caller guarantees `out` is writable for `capacity` bytes.
        let target = unsafe { std::slice::from_raw_parts_mut(out, capacity) };
        found.read_image(image, target)
    }))
    .unwrap_or(0)
}

/// # Safety
/// Pass an unchanged buffer returned by `akitty_request_v1`, exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn akitty_buffer_free_v1(buffer: AkittyBuffer) {
    if !buffer.data.is_null() {
        // SAFETY: the documented ABI requires original pointer and length, once.
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                buffer.data,
                buffer.len,
            )))
        };
    }
}
