use akitty_agent_core::chrome::now_ms;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::Path;

pub(crate) const SEGMENT: usize = 4 * 1_048_576;

pub fn identifier() -> Result<String, String> {
    let mut bytes = [0u8; 16];
    File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes)).map_err(|e| e.to_string())?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}
pub(crate) fn digest(command: &str) -> Value { json!({"command_sha256":format!("{:x}", Sha256::digest(command.as_bytes())),"command_bytes":command.len()}) }

pub(crate) fn private_directory(path: &Path) -> Result<File, String> {
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path).map_err(|e| e.to_string())?;
    let file = OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC).open(path).map_err(|e| e.to_string())?;
    let info = file.metadata().map_err(|e| e.to_string())?;
    // SAFETY: getuid has no preconditions.
    if info.uid() != unsafe { libc::getuid() } || info.mode() & 0o777 != 0o700 { return Err("private directory must be owned by you with mode 0700".into()); }
    Ok(file)
}

pub(crate) struct Store {
    directory: File, _lock: File, instance: String, sequence: u64, limit: usize,
    #[cfg(test)]
    pub fail_after: Option<usize>,
}
impl Store {
    pub fn new(path: &Path) -> Result<Self, String> { Self::with_limit(path, SEGMENT) }
    pub fn with_limit(path: &Path, limit: usize) -> Result<Self, String> {
        let directory = private_directory(path)?;
        let lock = Self::open_at(&directory, "writer.lock", true, limit)?;
        // SAFETY: lock owns the descriptor and remains alive until Store is dropped.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 { return Err("another instance owns event recording".into()); }
        let mut store = Self { directory, _lock: lock, instance: identifier()?, sequence: 0, limit,
            #[cfg(test)]
            fail_after: None,
        };
        let mut file = store.open("events.jsonl", true)?;
        let mut bytes = Vec::new(); file.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        if !bytes.is_empty() && bytes.last() != Some(&b'\n') {
            let end = bytes.iter().rposition(|b| *b == b'\n').map_or(0, |n| n + 1);
            file.set_len(end as u64).map_err(|e| e.to_string())?;
            store.append("incomplete_record_dropped", "host", "host", json!({"dropped_bytes":bytes.len()-end}))?;
        }
        Ok(store)
    }
    fn open_at(directory: &File, name: &str, create: bool, limit: usize) -> Result<File, String> {
        let name = std::ffi::CString::new(name).map_err(|e| e.to_string())?;
        let flags = libc::O_NOFOLLOW | libc::O_CLOEXEC | if create { libc::O_RDWR | libc::O_CREAT } else { libc::O_RDONLY };
        // SAFETY: directory is an owned directory descriptor; name is a constant relative C string.
        let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags, 0o600) };
        if fd < 0 { return Err(std::io::Error::last_os_error().to_string()); }
        // SAFETY: openat returned a new descriptor; File becomes its sole owner.
        let file = unsafe { File::from_raw_fd(fd) };
        let info = file.metadata().map_err(|e| e.to_string())?;
        // SAFETY: getuid has no preconditions.
        if !info.is_file() || info.uid() != unsafe { libc::getuid() } || info.mode() & 0o777 != 0o600 || info.nlink() != 1 || info.len() > limit as u64 { return Err("unsafe or oversized event file".into()); }
        Ok(file)
    }
    fn open(&self, name: &str, create: bool) -> Result<File, String> { Self::open_at(&self.directory, name, create, self.limit) }
    pub fn append(&mut self, event: &str, session: &str, source: &str, fields: Value) -> Result<(), String> {
        #[cfg(test)]
        if let Some(left) = self.fail_after.as_mut() {
            if *left == 0 { return Err("injected event storage failure".into()); }
            *left -= 1;
        }
        let mut file = self.open("events.jsonl", true)?;
        if file.metadata().map_err(|e| e.to_string())?.len() as usize + 8192 + 512 > self.limit {
            let fd = self.directory.as_raw_fd();
            // SAFETY: both paths are constants relative to the owned private directory.
            if unsafe { libc::renameat(fd, c"events.jsonl".as_ptr(), fd, c"previous.jsonl".as_ptr()) } != 0 { return Err(std::io::Error::last_os_error().to_string()); }
            file = self.open("events.jsonl", true)?;
            self.write(&mut file, "retention_rotated", session, "host", json!({"older_segments_may_be_missing":true}))?;
        }
        self.write(&mut file, event, session, source, fields)?;
        file.sync_all().and_then(|_| self.directory.sync_all()).map_err(|e| e.to_string())
    }
    fn write(&mut self, file: &mut File, event: &str, session: &str, source: &str, fields: Value) -> Result<(), String> {
        self.sequence += 1;
        let mut bytes = serde_json::to_vec(&json!({"version":1,"instance":self.instance,"sequence":self.sequence,
            "time_ms":now_ms(),"session":session,"event":event,"provenance":source,"fields":fields})).map_err(|e| e.to_string())?;
        bytes.push(b'\n');
        if bytes.len() > 8192 { return Err("event exceeds 8 KiB".into()); }
        file.seek(SeekFrom::End(0)).and_then(|_| file.write_all(&bytes)).map_err(|e| e.to_string())
    }
    pub fn export(&self) -> Result<String, String> {
        let mut bytes = Vec::new();
        for name in ["previous.jsonl", "events.jsonl"] {
            let c_name = std::ffi::CString::new(name).map_err(|e| e.to_string())?;
            // SAFETY: directory and constant filename remain valid; only checks existence.
            if unsafe { libc::faccessat(self.directory.as_raw_fd(), c_name.as_ptr(), libc::F_OK, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
                if std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound { continue; }
                return Err(std::io::Error::last_os_error().to_string());
            }
            let mut part = Vec::new(); self.open(name, false)?.take(self.limit as u64 + 1).read_to_end(&mut part).map_err(|e| e.to_string())?;
            if part.len() > self.limit { return Err("event segment grew beyond its limit".into()); }
            bytes.extend(part);
        }
        String::from_utf8(bytes).map_err(|e| e.to_string())
    }
}

pub(crate) fn export_to(path: &Path, text: &str) -> Result<(), String> {
    let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(path).map_err(|e| e.to_string())?;
    file.write_all(text.as_bytes()).and_then(|_| file.sync_all()).map_err(|e| e.to_string())
}
