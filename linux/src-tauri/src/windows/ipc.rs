use crate::Host;
use crate::windows::security::{self, Descriptor, check, error, owned, wide};
use serde::Deserialize;
use serde_json::{Value, json};
use std::fs::File;
use std::io::{Read, Write};
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::{Arc, Weak, atomic::{AtomicBool, Ordering}};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Pipes::*;

const MAX_FRAME: usize = 16384;
pub(crate) type Peer = File;
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    List { version: u8, #[serde(default)] offset: usize },
    Request { version: u8, pane: String, command: String },
}
pub struct Server { stop: Arc<AtomicBool>, worker: Option<JoinHandle<()>> }
impl Server {
    pub fn start(host: &Arc<Host>, path: &Path) -> Result<Self, String> {
        validate_path(path)?;
        let descriptor = Descriptor::new()?; let attributes = descriptor.attributes();
        // One retained instance and FIRST_PIPE_INSTANCE prevent endpoint replacement/competing servers.
        // SAFETY: path and security attributes remain live for this synchronous creation call.
        let pipe = unsafe { owned(CreateNamedPipeW(wide(path).as_ptr(), PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 32768, 32768, 0, &attributes)) }?;
        let stream = File::from(pipe);
        let stop = Arc::new(AtomicBool::new(false)); let worker_stop = stop.clone(); let weak = Arc::downgrade(host);
        let worker = thread::Builder::new().name("akitty-agent-pipe".into()).spawn(move || serve(stream, weak, worker_stop)).map_err(|e| e.to_string())?;
        Ok(Self { stop, worker: Some(worker) })
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() { let _ = worker.join(); }
    }
}
fn serve(mut stream: File, host: Weak<Host>, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::SeqCst) {
        // SAFETY: stream owns a nonblocking named-pipe server handle; no OVERLAPPED is used.
        let ready = unsafe { ConnectNamedPipe(stream.as_raw_handle(), null_mut()) };
        // SAFETY: GetLastError has no preconditions.
        let code = unsafe { GetLastError() };
        if ready != 0 || code == ERROR_PIPE_CONNECTED {
            handle(&mut stream, host.clone(), &stop);
            // SAFETY: disconnect only the server's current client; retain the first-instance handle.
            unsafe { DisconnectNamedPipe(stream.as_raw_handle()); }
        } else if code == ERROR_PIPE_LISTENING || code == ERROR_NO_DATA {
            if code == ERROR_NO_DATA {
                // SAFETY: a prior client disconnected before sending a request.
                unsafe { DisconnectNamedPipe(stream.as_raw_handle()); }
            }
            thread::sleep(Duration::from_millis(10));
        } else {
            if let Some(host) = host.upgrade() { host.transport_failed(format!("named pipe accept failed: {code}")); }
            break;
        }
    }
}
fn peer(stream: &File, server: bool) -> Result<u32, String> {
    let mut pid = 0;
    // SAFETY: pipe handle is live and pid is writable; select the endpoint's opposite process.
    check(unsafe { if server { GetNamedPipeClientProcessId(stream.as_raw_handle(), &mut pid) } else { GetNamedPipeServerProcessId(stream.as_raw_handle(), &mut pid) } })?;
    if security::identity(Some(pid))? != security::identity(None)? { return Err("named pipe peer must be the same user and Windows session".into()); }
    Ok(pid)
}
pub(crate) fn connected(stream: &Peer) -> bool {
    let mut available = 0;
    // SAFETY: peek never consumes bytes and available is writable.
    unsafe { PeekNamedPipe(stream.as_raw_handle(), null_mut(), 0, null_mut(), &mut available, null_mut()) != 0 && available == 0 }
}
fn handle(stream: &mut File, host: Weak<Host>, stop: &AtomicBool) {
    let result = (|| {
        let pid = peer(stream, true)?;
        let bytes = read_frame(stream, Duration::from_secs(3), stop)?;
        if !connected(stream) { return Err("requester disconnected or sent extra data".into()); }
        let request: Request = serde_json::from_slice(&bytes).map_err(|e| format!("invalid request: {e}"))?;
        let host = host.upgrade().ok_or("host stopped")?;
        match request {
            Request::List { version: 1, offset } => host.list(offset),
            Request::Request { version: 1, pane, command } => {
                let receiver = host.request(pane, command, pid, stream.try_clone().map_err(|e| e.to_string())?)?;
                loop {
                    if stop.load(Ordering::SeqCst) || !connected(stream) { return Err("request canceled".into()); }
                    match receiver.recv_timeout(Duration::from_millis(25)) {
                        Ok(result) => return result,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {},
                        Err(_) => return Err("host stopped".into()),
                    }
                }
            }
            _ => Err("unsupported request version".into()),
        }
    })();
    let response = match result { Ok(data) => json!({"version":1,"ok":true,"data":data}), Err(error) => json!({"version":1,"ok":false,"error":error}) };
    if let Ok(bytes) = serde_json::to_vec(&response) && write_frame(stream, &bytes).is_ok() {
        // DisconnectNamedPipe discards unread responses. Wait for one bounded receipt byte,
        // rather than blocking indefinitely in FlushFileBuffers on an unresponsive caller.
        let _ = read_exact(stream, &mut [0u8; 1], Instant::now()+Duration::from_secs(1), stop);
    }
}
fn read_exact(stream: &mut File, bytes: &mut [u8], deadline: Instant, stop: &AtomicBool) -> Result<(), String> {
    let mut offset = 0;
    while offset < bytes.len() {
        if stop.load(Ordering::SeqCst) || Instant::now() >= deadline { return Err("pipe read canceled or timed out".into()); }
        let mut available = 0;
        // SAFETY: stream is a live pipe; output pointer is writable.
        check(unsafe { PeekNamedPipe(stream.as_raw_handle(), null_mut(), 0, null_mut(), &mut available, null_mut()) })?;
        if available == 0 { thread::sleep(Duration::from_millis(5)); continue; }
        let count = (available as usize).min(bytes.len()-offset);
        let n = stream.read(&mut bytes[offset..offset+count]).map_err(|e| e.to_string())?;
        if n == 0 { return Err("pipe closed".into()); }
        offset += n;
    }
    Ok(())
}
fn read_frame(stream: &mut File, duration: Duration, stop: &AtomicBool) -> Result<Vec<u8>, String> {
    let deadline = Instant::now()+duration; let mut header = [0u8; 4];
    read_exact(stream, &mut header, deadline, stop)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_FRAME { return Err("invalid frame length".into()); }
    let mut bytes = vec![0; length]; read_exact(stream, &mut bytes, deadline, stop)?; Ok(bytes)
}
fn write_frame(stream: &mut File, bytes: &[u8]) -> Result<(), String> {
    if bytes.is_empty() || bytes.len() > MAX_FRAME { return Err("frame exceeds bounds".into()); }
    let bytes = [&(bytes.len() as u32).to_be_bytes()[..], bytes].concat();
    let deadline = Instant::now()+Duration::from_secs(3); let mut offset = 0;
    while offset < bytes.len() {
        if Instant::now() >= deadline { return Err("pipe write timed out".into()); }
        match stream.write(&bytes[offset..]) {
            Ok(0) => thread::sleep(Duration::from_millis(5)),
            Ok(n) => offset += n,
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}
fn validate_path(path: &Path) -> Result<(), String> {
    let name = path.to_str().ok_or("invalid pipe name")?;
    let suffix = name.strip_prefix(r"\\.\pipe\AkiTTY-Experimental-").ok_or("only local AkiTTY Experimental named pipes are allowed")?;
    if suffix.is_empty() || suffix.len() > 180 || !suffix.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') { return Err("invalid pipe name".into()); }
    Ok(())
}
pub fn default_socket() -> Result<PathBuf, String> {
    let (sid, session) = security::identity(None)?;
    Ok(PathBuf::from(format!(r"\\.\pipe\AkiTTY-Experimental-{sid}-{session}")))
}
fn client(path: &Path) -> Result<File, String> {
    validate_path(path)?;
    // Wait only before a connection exists; never reconnect/retry after request bytes are sent.
    // This covers the preceding client's short receipt/disconnect interval.
    let deadline = Instant::now()+Duration::from_secs(1);
    let handle = loop {
        // Identification-only SQOS prevents a fake same-user server from impersonating the caller.
        // SAFETY: path is terminated; this opens only an existing local named pipe.
        let raw = unsafe { CreateFileW(wide(path).as_ptr(), GENERIC_READ | GENERIC_WRITE, 0, null(), OPEN_EXISTING,
            SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, null_mut()) };
        if raw != INVALID_HANDLE_VALUE {
            // SAFETY: CreateFileW returned a new owned handle.
            break unsafe { owned(raw) }?;
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(ERROR_PIPE_BUSY as i32) || Instant::now() >= deadline { return Err(error()); }
        thread::sleep(Duration::from_millis(5));
    };
    let stream = File::from(handle); peer(&stream, false)?;
    let mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
    // SAFETY: mode pointer and live pipe handle are valid.
    check(unsafe { SetNamedPipeHandleState(stream.as_raw_handle(), &mode, null(), null()) })?;
    Ok(stream)
}
#[cfg(test)]
pub(crate) fn begin_test(path: &Path, request: &Value) -> Result<File, String> {
    let mut stream = client(path)?;
    write_frame(&mut stream, &serde_json::to_vec(request).map_err(|e| e.to_string())?)?;
    Ok(stream)
}
pub fn call(path: &Path, request: &Value) -> Result<Value, String> {
    let mut stream = client(path)?;
    let result = (|| {
        write_frame(&mut stream, &serde_json::to_vec(request).map_err(|e| e.to_string())?)?;
        let bytes = read_frame(&mut stream, Duration::from_secs(125), &AtomicBool::new(false))?;
        let response = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        stream.write_all(&[1]).map_err(|_| error())?; Ok(response)
    })();
    result.map_err(|error| if request["op"] == "request" { format!("request outcome may be unknown; inspect and reclaim; do not retry automatically: {error}") } else { error })
}
