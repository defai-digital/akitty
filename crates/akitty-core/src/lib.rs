//! Akitty's versioned, macOS-only terminal boundary.
#![deny(unsafe_op_in_unsafe_fn)]
#[cfg(not(target_os = "macos"))]
compile_error!("Akitty supports macOS only");

mod model;
mod session;

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
}

#[derive(Default)]
struct Registry {
    next_id: u64,
    sessions: HashMap<u64, Arc<session::Session>>,
}
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();

pub fn request(bytes: &[u8]) -> Value {
    match catch_unwind(AssertUnwindSafe(|| dispatch(bytes))) {
        Ok(Ok(data)) => json!({"version": ABI_VERSION, "ok": true, "data": data}),
        Ok(Err(error)) => json!({"version": ABI_VERSION, "ok": false, "error": error}),
        Err(_) => {
            json!({"version": ABI_VERSION, "ok": false, "error": "internal panic; recreate affected session"})
        }
    }
}

fn dispatch(bytes: &[u8]) -> Result<Value, String> {
    if bytes.len() > MAX_REQUEST {
        return Err("request exceeds 1 MiB".into());
    }
    let request: Request = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    let mut registry = REGISTRY
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match request {
        Request::Version {} => Ok(
            json!({"abi": ABI_VERSION, "schema": 1, "platform": "macos", "engine": "alacritty_terminal 0.26.0"}),
        ),
        Request::Create {
            cols,
            rows,
            shell,
            cwd,
            headless,
        } => {
            model::Size::validate(cols, rows)?;
            if registry.sessions.len() >= 64 {
                return Err("session limit reached".into());
            }
            registry.next_id = registry
                .next_id
                .checked_add(1)
                .ok_or("session ID exhausted")?;
            let id = registry.next_id;
            drop(registry);
            let session = Arc::new(session::Session::new(
                cols,
                rows,
                shell,
                cwd,
                headless.unwrap_or(false),
            )?);
            let mut registry = REGISTRY
                .get()
                .unwrap()
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            if registry.sessions.len() >= 64 {
                drop(registry);
                session.close()?;
                return Err("session limit reached".into());
            }
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
                | Request::Select { id, .. }
                | Request::Find { id, .. } => *id,
                _ => unreachable!(),
            };
            let session = registry
                .sessions
                .get(&id)
                .cloned()
                .ok_or("unknown or closed session")?;
            drop(registry);
            match request {
                Request::Snapshot { since, .. } => session.snapshot(since),
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
                Request::Select {
                    start_row,
                    start_col,
                    end_row,
                    end_col,
                    ..
                } => session.select(start_row, start_col, end_row, end_col),
                Request::Find { text, .. } => session.find(&text),
                _ => unreachable!(),
            }
        }
    }
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
        let response = if len > MAX_REQUEST || data.is_null() {
            json!({"version": 1, "ok": false, "error": "invalid request buffer"})
        } else {
            // SAFETY: caller supplies a live byte slice; the bound is checked above.
            request(unsafe { std::slice::from_raw_parts(data, len) })
        };
        let mut bytes = serde_json::to_vec(&response).unwrap_or_default();
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
