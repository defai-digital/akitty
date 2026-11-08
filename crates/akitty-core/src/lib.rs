//! Akitty's versioned, macOS-only terminal boundary.
#![deny(unsafe_op_in_unsafe_fn)]
#[cfg(not(target_os = "macos"))]
compile_error!("Akitty supports macOS only");

mod child;
mod chrome;
mod control;
mod graphics;
mod media;
mod model;
mod placeholder;
mod program_status;
mod session;
mod shell;

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
        shell_integration_dir: Option<String>,
        folder_history: Option<bool>,
    },
    ControlAcquire { id: u64, actor: String },
    ControlRelease { id: u64, lease: u64 },
    ControlReclaim { id: u64 },
    CommandAuthorize { id: u64, lease: u64, command: String, expected_cwd: Option<String> },
    CommandExecute { id: u64, lease: u64, authorization: u64, command: String },
    CommandDeny { id: u64, lease: u64 },
    ControlAudit { id: u64, after: Option<u64> },
    CommandHistory { id: u64, after: Option<u64> },
    ShellState { id: u64 },
    CommandOutput { id: u64, command_id: u64 },
    Close {
        id: u64,
    },
    Snapshot {
        id: u64,
        since: Option<u64>,
        compact: Option<bool>,
        allow_shift: Option<bool>,
        /// `binary` opts into the binary cell block; only honored together with `compact`.
        cells: Option<String>,
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
        #[serde(default)]
        text: String,
        /// `latest` (default), `next`, or `previous`.
        #[serde(default)]
        direction: Option<String>,
        /// Drop the current highlight. `text` is ignored.
        #[serde(default)]
        clear: bool,
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
    /// Read end of a pipe the core writes when the model revision advances. The core owns both
    /// ends and closes them on `close`; the host must stop reading before closing the session.
    NotifyFd { id: u64 },
}

#[derive(Default)]
struct Registry {
    next_id: u64,
    /// Sessions being spawned outside the lock; they count against the cap.
    creating: usize,
    sessions: HashMap<u64, Arc<session::Session>>,
}
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();

/// Response data: a value, JSON a hot path (snapshots) already serialized, or that JSON
/// followed by a NUL and a raw binary cell block.
enum Reply {
    Value(Value),
    Json(String),
    JsonBinary { json: String, binary: Vec<u8> },
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
        Reply::Json(json) | Reply::JsonBinary { json, .. } => serde_json::from_str(&json).map_err(|e| e.to_string()),
    }))
}

/// The serialized response envelope for one request.
fn lock_registry() -> std::sync::MutexGuard<'static, Registry> {
    REGISTRY.get_or_init(Default::default).lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct CreatingSlot;

impl Drop for CreatingSlot {
    fn drop(&mut self) {
        lock_registry().creating -= 1;
    }
}

fn respond(bytes: &[u8]) -> Vec<u8> {
    let result = match guarded(bytes) {
        Ok(Reply::Json(json)) => return envelope_json(&json, None),
        // One response: the JSON head, a NUL (JSON never contains one), then the cell block.
        Ok(Reply::JsonBinary { json, binary }) => return envelope_json(&json, Some(&binary)),
        Ok(Reply::Value(value)) => Ok(value),
        Err(error) => Err(error),
    };
    serde_json::to_vec(&envelope(result)).unwrap_or_default()
}

fn envelope_json(json: &str, binary: Option<&[u8]>) -> Vec<u8> {
    let mut out = Vec::with_capacity(json.len() + 64 + binary.map_or(0, |block| block.len() + 1));
    out.extend_from_slice(format!(r#"{{"version":{ABI_VERSION},"ok":true,"data":"#).as_bytes());
    out.extend_from_slice(json.as_bytes());
    out.push(b'}');
    if let Some(block) = binary {
        out.push(0);
        out.extend_from_slice(block);
    }
    out
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
            json!({"abi": ABI_VERSION, "schema": 1, "platform": "macos", "engine": "akitty-vt"}),
        ),
        Request::Create {
            cols,
            rows,
            shell,
            cwd,
            headless,
            scrollback,
            shell_integration_dir,
            folder_history,
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
            // Releases the reserved slot even if `Session::new` panics; `guarded` catches the
            // panic, and without this each one would leak a slot until Create always failed.
            let reservation = CreatingSlot;
            let created = session::Session::new(
                cols,
                rows,
                shell,
                cwd,
                headless.unwrap_or(false),
                scrollback.unwrap_or(5000),
                shell_integration_dir.map(|directory| session::ShellIntegration {
                    directory,
                    folder_history: folder_history.unwrap_or(true),
                }),
            );
            let mut registry = lock_registry();
            std::mem::forget(reservation);
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
                | Request::ControlAcquire { id, .. }
                | Request::ControlRelease { id, .. }
                | Request::ControlReclaim { id }
                | Request::CommandAuthorize { id, .. }
                | Request::CommandExecute { id, .. }
                | Request::CommandDeny { id, .. }
                | Request::ControlAudit { id, .. }
                | Request::CommandHistory { id, .. }
                | Request::ShellState { id }
                | Request::CommandOutput { id, .. }
                | Request::Input { id, .. }
                | Request::InputBytes { id, .. }
                | Request::Feed { id, .. }
                | Request::Resize { id, .. }
                | Request::Scroll { id, .. }
                | Request::CellSize { id, .. }
                | Request::Select { id, .. }
                | Request::Find { id, .. }
                | Request::Chrome { id, .. }
                | Request::ProgramChrome { id, .. }
                | Request::NotifyFd { id } => *id,
                _ => unreachable!(),
            };
            let session = registry
                .sessions
                .get(&id)
                .cloned()
                .ok_or("unknown or closed session")?;
            drop(registry);
            match request {
                Request::ControlAcquire { actor, .. } => session.control_acquire(actor),
                Request::ControlRelease { lease, .. } => session.control_release(Some(lease)),
                Request::ControlReclaim { .. } => session.control_release(None),
                Request::CommandAuthorize { lease, command, expected_cwd, .. } => session.command_authorize(lease, command, expected_cwd),
                Request::CommandDeny { lease, .. } => session.command_deny(lease),
                Request::CommandExecute { lease, authorization, command, .. } => session.command_execute(lease, authorization, command),
                Request::ControlAudit { after, .. } => session.control_audit(after.unwrap_or(0)),
                Request::CommandHistory { after, .. } => session.command_history(after.unwrap_or(0)),
                Request::ShellState { .. } => session.shell_state(),
                Request::CommandOutput { command_id, .. } => session.command_output(command_id),
                Request::Snapshot { since, compact, allow_shift, cells, .. } => {
                    let compact = compact.unwrap_or(false);
                    // Binary is an opt-in negotiation and only replaces compact cells.
                    let binary = compact && cells.as_deref() == Some("binary");
                    let (json, block) = session.snapshot_with(since, compact, allow_shift.unwrap_or(false), binary)?;
                    return Ok(match block {
                        Some(binary) => Reply::JsonBinary { json, binary },
                        None => Reply::Json(json),
                    });
                }
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
                Request::Find { text, direction, clear, .. } => session.find(&text, direction.as_deref(), clear),
                Request::Chrome { clear, status, mark, progress, sprite, .. } => {
                    session.set_chrome(chrome::ChromeInput { clear, status, mark, progress, sprite: sprite.map(|value| *value) })?;
                    Ok(json!({}))
                }
                Request::ProgramChrome { enabled, .. } => {
                    session.set_program_chrome(enabled)?;
                    Ok(json!({}))
                }
                Request::NotifyFd { .. } => session.notify_fd(),
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The Swift idle-poll shortcut compares the unchanged reply byte-for-byte, so the
    /// wire bytes are pinned here; a change on either side breaks this test first.
    #[test]
    fn unchanged_snapshot_envelope_is_exact() {
        let created: Value =
            serde_json::from_slice(&respond(br#"{"op":"create","cols":20,"rows":4,"headless":true}"#)).unwrap();
        let id = created["data"]["id"].as_u64().expect("session id");
        let full: Value =
            serde_json::from_slice(&respond(format!(r#"{{"op":"snapshot","id":{id}}}"#).as_bytes())).unwrap();
        assert_eq!(full["ok"], true, "first snapshot failed: {full}");
        let revision = full["data"]["revision"].as_u64().expect("revision");
        let unchanged =
            respond(format!(r#"{{"op":"snapshot","id":{id},"since":{revision},"compact":true,"allow_shift":true}}"#).as_bytes());
        assert_eq!(unchanged.as_slice(), br#"{"version":1,"ok":true,"data":{"changed":false}}"#.as_slice());
        let _ = respond(format!(r#"{{"op":"close","id":{id}}}"#).as_bytes());
    }

    #[test]
    fn negotiated_binary_cells_follow_a_nul_separator() {
        let created: Value =
            serde_json::from_slice(&respond(br#"{"op":"create","cols":20,"rows":4,"headless":true}"#)).unwrap();
        let id = created["data"]["id"].as_u64().expect("session id");
        let fed = respond(format!(
            r#"{{"op":"feed","id":{id},"text":"\u001b[31mhello\u001b[0m \u001b[4m\u001b[58;2;1;2;3mworld"}}"#
        ).as_bytes());
        assert_eq!(serde_json::from_slice::<Value>(&fed).unwrap()["ok"], true);
        let bytes = respond(format!(r#"{{"op":"snapshot","id":{id},"compact":true,"cells":"binary"}}"#).as_bytes());
        // A raw NUL is the separator; JSON output never contains one.
        let nul = bytes.iter().position(|byte| *byte == 0).expect("binary reply must carry a NUL separator");
        let head: Value = serde_json::from_slice(&bytes[..nul]).unwrap();
        assert_eq!(head["ok"], true, "{head}");
        assert_eq!(head["data"]["cells"], json!([]));
        let meta = &head["data"]["cells_binary"];
        assert_eq!(meta["version"], 1);
        assert!(meta["count"].as_u64().unwrap() > 0);
        assert_eq!(meta["bytes"].as_u64().unwrap() as usize, bytes.len() - nul - 1);
        // The head is valid JSON; the whole reply is not, because the block follows it.
        assert!(serde_json::from_slice::<Value>(&bytes).is_err());
        // Without compact the negotiation is ignored, and without the field nothing changes.
        for plain in [
            format!(r#"{{"op":"snapshot","id":{id},"cells":"binary"}}"#),
            format!(r#"{{"op":"snapshot","id":{id},"compact":true}}"#),
        ] {
            let reply = respond(plain.as_bytes());
            assert!(!reply.contains(&0), "JSON-cells replies must stay NUL-free");
            let value: Value = serde_json::from_slice(&reply).unwrap();
            assert!(!value["data"]["cells"].as_array().unwrap().is_empty(), "{value}");
        }
        let _ = respond(format!(r#"{{"op":"close","id":{id}}}"#).as_bytes());
        // A blank screen carries zero cells: the block is empty and only the NUL remains.
        let blank: Value =
            serde_json::from_slice(&respond(br#"{"op":"create","cols":20,"rows":4,"headless":true}"#)).unwrap();
        let blank_id = blank["data"]["id"].as_u64().expect("blank session id");
        let empty = respond(format!(r#"{{"op":"snapshot","id":{blank_id},"compact":true,"cells":"binary"}}"#).as_bytes());
        let nul = empty.iter().position(|byte| *byte == 0).expect("an empty block keeps the separator");
        let head: Value = serde_json::from_slice(&empty[..nul]).unwrap();
        assert_eq!(head["data"]["cells_binary"]["count"], 0);
        assert_eq!(head["data"]["cells_binary"]["bytes"], 0);
        assert_eq!(empty.len(), nul + 1, "no bytes may follow an empty block");
        let _ = respond(format!(r#"{{"op":"close","id":{blank_id}}}"#).as_bytes());
    }
}
