use crate::Host;
use crate::store::private_directory;
use serde::Deserialize;
use serde_json::{Value, json};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak, atomic::{AtomicBool, Ordering}};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub(crate) type Peer = UnixStream;

const MAX_FRAME: usize = 16384;
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    List { version: u8, #[serde(default)] offset: usize },
    Request { version: u8, pane: String, command: String },
}

pub struct Server { stop: Arc<AtomicBool>, worker: Option<JoinHandle<()>>, path: PathBuf, inode: u64, _lock: File }
impl Server {
    pub fn start(host: &Arc<Host>, path: &Path) -> Result<Self, String> {
        if !path.is_absolute() || path.as_os_str().len() > 100 { return Err("socket path must be absolute and at most 100 bytes".into()); }
        let parent = path.parent().ok_or("missing socket directory")?;
        let _directory = private_directory(parent)?;
        let lock = OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(parent.join("owner.lock")).map_err(|e| e.to_string())?;
        let info = lock.metadata().map_err(|e| e.to_string())?;
        // SAFETY: getuid has no preconditions; flock uses an owned descriptor.
        if !info.is_file() || info.nlink() != 1 || info.uid() != unsafe { libc::getuid() } || info.mode() & 0o777 != 0o600
            || unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 { return Err("another instance owns local requests or lock is unsafe".into()); }
        if let Ok(info) = std::fs::symlink_metadata(path) {
            // SAFETY: getuid has no preconditions.
            if !info.file_type().is_socket() || info.uid() != unsafe { libc::getuid() } { return Err("unsafe existing socket path".into()); }
            std::fs::remove_file(path).map_err(|e| e.to_string())?;
        }
        let listener = UnixListener::bind(path).map_err(|e| e.to_string())?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
        listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let inode = std::fs::symlink_metadata(path).map_err(|e| e.to_string())?.ino();
        let stop = Arc::new(AtomicBool::new(false)); let thread_stop = stop.clone(); let weak = Arc::downgrade(host);
        let worker = thread::Builder::new().name("akitty-agent-ipc".into()).spawn(move || serve(listener, weak, thread_stop)).map_err(|e| e.to_string())?;
        Ok(Self { stop, worker: Some(worker), path: path.to_path_buf(), inode, _lock: lock })
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() { let _ = worker.join(); }
        if std::fs::symlink_metadata(&self.path).is_ok_and(|m| m.ino() == self.inode) { let _ = std::fs::remove_file(&self.path); }
    }
}
fn serve(listener: UnixListener, host: Weak<Host>, stop: Arc<AtomicBool>) {
    let busy = Arc::new(AtomicBool::new(false));
    let mut client: Option<JoinHandle<()>> = None;
    while !stop.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => {
                if busy.swap(true, Ordering::SeqCst) { drop(stream); continue; }
                if let Some(previous) = client.take() { let _ = previous.join(); }
                let weak = host.clone(); let client_busy = busy.clone(); let client_stop = stop.clone();
                client = Some(thread::spawn(move || { handle(stream, weak, &client_stop); client_busy.store(false, Ordering::SeqCst); }));
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => thread::sleep(Duration::from_millis(10)),
            Err(error) => { if let Some(host) = host.upgrade() { host.transport_failed(error.to_string()); } break; }
        }
    }
    if let Some(client) = client { let _ = client.join(); }
}
fn handle(mut stream: UnixStream, host: Weak<Host>, stop: &AtomicBool) {
    let result = (|| {
        let pid = peer(&stream)?;
        let bytes = read_frame(&mut stream, Duration::from_secs(3))?;
        if !connected(&stream) { return Err("requester disconnected".into()); }
        let request: Request = serde_json::from_slice(&bytes).map_err(|e| format!("invalid request: {e}"))?;
        let host = host.upgrade().ok_or("host stopped")?;
        match request {
            Request::List { version: 1, offset } => host.list(offset),
            Request::Request { version: 1, pane, command } => {
                let receiver = host.request(pane, command, pid, stream.try_clone().map_err(|e| e.to_string())?)?;
                loop {
                    if stop.load(Ordering::SeqCst) || !connected(&stream) { return Err("request canceled".into()); }
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
    let _ = write_frame(&mut stream, &serde_json::to_vec(&response).unwrap_or_default());
}
fn peer(stream: &UnixStream) -> Result<u32, String> {
    #[cfg(target_os = "linux")]
    {
        let mut credentials = libc::ucred { pid: 0, uid: 0, gid: 0 };
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        // SAFETY: both pointers reference initialized values of the declared lengths.
        if unsafe { libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, (&mut credentials as *mut libc::ucred).cast(), &mut length) } != 0
            || length as usize != std::mem::size_of::<libc::ucred>() || credentials.pid <= 0
            // SAFETY: getuid has no preconditions.
            || credentials.uid != unsafe { libc::getuid() } { return Err("local peer credentials unavailable or not permitted".into()); }
        Ok(credentials.pid as u32)
    }
    #[cfg(not(target_os = "linux"))]
    { let _ = stream; Err("agent IPC is Linux-only".into()) }
}
pub(crate) fn connected(stream: &UnixStream) -> bool {
    let mut byte = 0u8;
    // SAFETY: byte is writable; MSG_PEEK does not consume data and MSG_DONTWAIT never blocks.
    let count = unsafe { libc::recv(stream.as_raw_fd(), (&mut byte as *mut u8).cast(), 1, libc::MSG_PEEK | libc::MSG_DONTWAIT) };
    // Extra data violates the single-request protocol; EOF includes half-closed writes.
    count < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock
}
fn read_until(stream: &mut UnixStream, bytes: &mut [u8], deadline: Instant) -> Result<(), String> {
    let mut offset = 0;
    while offset < bytes.len() {
        let left = deadline.checked_duration_since(Instant::now()).ok_or("frame deadline exceeded")?;
        stream.set_read_timeout(Some(left)).map_err(|e| e.to_string())?;
        let read = stream.read(&mut bytes[offset..]).map_err(|e| e.to_string())?;
        if read == 0 { return Err("incomplete request frame".into()); }
        offset += read;
    }
    Ok(())
}
pub fn read_frame(stream: &mut UnixStream, timeout: Duration) -> Result<Vec<u8>, String> {
    let deadline = Instant::now()+timeout;
    let mut prefix = [0u8; 4]; read_until(stream, &mut prefix, deadline)?;
    let length = u32::from_be_bytes(prefix) as usize;
    if length == 0 || length > MAX_FRAME { return Err("frame must be 1..16384 bytes".into()); }
    let mut bytes = vec![0; length]; read_until(stream, &mut bytes, deadline)?; Ok(bytes)
}
pub fn write_frame(stream: &mut UnixStream, bytes: &[u8]) -> Result<(), String> {
    if bytes.is_empty() || bytes.len() > MAX_FRAME { return Err("frame exceeds bounds".into()); }
    stream.set_write_timeout(Some(Duration::from_secs(3))).map_err(|e| e.to_string())?;
    stream.write_all(&(bytes.len() as u32).to_be_bytes()).and_then(|_| stream.write_all(bytes)).map_err(|e| e.to_string())
}
pub fn default_socket() -> Result<PathBuf, String> {
    let root = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).ok_or("XDG_RUNTIME_DIR is required; use --socket for an explicit private endpoint")?;
    Ok(root.join("akitty-experimental/requests.sock"))
}
pub fn call(path: &Path, request: &Value) -> Result<Value, String> {
    let mut stream = UnixStream::connect(path).map_err(|e| e.to_string())?;
    peer(&stream)?;
    let result = (|| {
        write_frame(&mut stream, &serde_json::to_vec(request).map_err(|e| e.to_string())?)?;
        serde_json::from_slice(&read_frame(&mut stream, Duration::from_secs(125))?).map_err(|e| e.to_string())
    })();
    result.map_err(|error| if request["op"] == "request" {
        format!("request outcome may be unknown; inspect the terminal and reclaim control; do not retry automatically: {error}")
    } else { error })
}
