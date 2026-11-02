use crate::windows::security::{Descriptor, check, owned, private_handle, wide};
use akitty_agent_core::chrome::now_ms;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Cryptography::*;
use windows_sys::Win32::Storage::FileSystem::*;

const SEGMENT: usize = 4 * 1_048_576;
pub fn identifier() -> Result<String, String> {
    let mut bytes = [0u8; 16];
    // SAFETY: system RNG writes exactly the buffer's declared length; no algorithm handle needed.
    let status = unsafe { BCryptGenRandom(null_mut(), bytes.as_mut_ptr(), bytes.len() as u32, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    if status != 0 { return Err(format!("system random generation failed: {status}")); }
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}
pub(crate) fn digest(command: &str) -> Value { json!({"command_sha256":format!("{:x}", Sha256::digest(command.as_bytes())),"command_bytes":command.len()}) }
fn no_reparse(path: &Path) -> Result<(), String> {
    for ancestor in path.ancestors().filter(|p| p.parent().is_some()) {
        // SAFETY: wide path is terminated and remains live through the call.
        let attributes = unsafe { GetFileAttributesW(wide(ancestor).as_ptr()) };
        if attributes != INVALID_FILE_ATTRIBUTES && attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 { return Err("reparse points are not allowed for private storage".into()); }
    }
    Ok(())
}
fn open(path: &Path, disposition: u32, directory: bool, share: u32, limit: usize) -> Result<File, String> {
    no_reparse(path)?;
    let descriptor = Descriptor::new()?; let attributes = descriptor.attributes();
    let flags = FILE_FLAG_OPEN_REPARSE_POINT | if directory { FILE_FLAG_BACKUP_SEMANTICS } else { 0 };
    let access = if directory { FILE_LIST_DIRECTORY | READ_CONTROL } else { GENERIC_READ | GENERIC_WRITE };
    // SAFETY: path and attributes are valid; successful creation transfers a new handle.
    let handle = unsafe { owned(CreateFileW(wide(path).as_ptr(), access, share, &attributes, disposition, flags, null_mut())) }?;
    private_handle(handle.as_raw_handle())?;
    let file = File::from(handle); let mut info: BY_HANDLE_FILE_INFORMATION = Default::default();
    // SAFETY: info is writable and file owns its handle.
    check(unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) })?;
    if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 || (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) != directory
        || !directory && (info.nNumberOfLinks != 1 || file.metadata().map_err(|e| e.to_string())?.len() > limit as u64) {
        return Err("unsafe or oversized private object".into());
    }
    Ok(file)
}
fn private_directory(path: &Path) -> Result<File, String> {
    if !path.is_absolute() { return Err("private directory must be absolute".into()); }
    no_reparse(path)?;
    if !path.exists() {
        let parent = path.parent().ok_or("missing private directory parent")?;
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        no_reparse(parent)?;
        let descriptor = Descriptor::new()?; let attributes = descriptor.attributes();
        // SAFETY: descriptor and terminated path are live; inheritance is restricted to this user.
        check(unsafe { CreateDirectoryW(wide(path).as_ptr(), &attributes) })?;
    }
    // Omitting FILE_SHARE_DELETE pins the private directory during recording.
    open(path, OPEN_EXISTING, true, FILE_SHARE_READ | FILE_SHARE_WRITE, 0)
}
pub(crate) struct Store {
    path: PathBuf, _directory: File, _lock: File, instance: String, sequence: u64, limit: usize,
    #[cfg(test)]
    pub fail_after: Option<usize>,
}
impl Store {
    pub fn new(path: &Path) -> Result<Self, String> { Self::with_limit(path, SEGMENT) }
    pub fn with_limit(path: &Path, limit: usize) -> Result<Self, String> {
        let directory = private_directory(path)?;
        let lock = open(&path.join("writer.lock"), OPEN_ALWAYS, false, 0, limit)?;
        let mut store = Self { path: path.into(), _directory: directory, _lock: lock, instance: identifier()?, sequence: 0, limit,
            #[cfg(test)]
            fail_after: None,
        };
        let mut file = store.open("events.jsonl", true)?;
        let mut bytes = Vec::new(); file.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        if !bytes.is_empty() && bytes.last() != Some(&b'\n') {
            let end = bytes.iter().rposition(|b| *b == b'\n').map_or(0, |n| n+1);
            file.set_len(end as u64).and_then(|_| file.sync_all()).map_err(|e| e.to_string())?;
            drop(file);
            store.append("incomplete_record_dropped", "host", "host", json!({"dropped_bytes":bytes.len()-end}))?;
        }
        Ok(store)
    }
    fn open(&self, name: &str, create: bool) -> Result<File, String> {
        private_handle(self._directory.as_raw_handle())?;
        open(&self.path.join(name), if create { OPEN_ALWAYS } else { OPEN_EXISTING }, false, FILE_SHARE_READ, self.limit)
    }
    pub fn append(&mut self, event: &str, session: &str, source: &str, fields: Value) -> Result<(), String> {
        #[cfg(test)]
        if let Some(left) = self.fail_after.as_mut() {
            if *left == 0 { return Err("injected event storage failure".into()); }
            *left -= 1;
        }
        let mut file = self.open("events.jsonl", true)?;
        if file.metadata().map_err(|e| e.to_string())?.len() as usize + 8192 + 512 > self.limit {
            drop(file);
            let previous = self.path.join("previous.jsonl");
            if previous.exists() { drop(self.open("previous.jsonl", false)?); }
            // SAFETY: paths are within a pinned private directory; replacement is bounded to one segment.
            check(unsafe { MoveFileExW(wide(self.path.join("events.jsonl")).as_ptr(), wide(previous).as_ptr(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) })?;
            file = self.open("events.jsonl", true)?;
            self.write(&mut file, "retention_rotated", session, "host", json!({"older_segments_may_be_missing":true}))?;
        }
        self.write(&mut file, event, session, source, fields)?;
        file.sync_all().map_err(|e| e.to_string())
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
            if !self.path.join(name).try_exists().map_err(|e| e.to_string())? { continue; }
            let mut part = Vec::new(); self.open(name, false)?.take(self.limit as u64+1).read_to_end(&mut part).map_err(|e| e.to_string())?;
            if part.len() > self.limit { return Err("event segment grew beyond its limit".into()); }
            bytes.extend(part);
        }
        String::from_utf8(bytes).map_err(|e| e.to_string())
    }
}
pub(crate) fn export_to(path: &Path, text: &str) -> Result<(), String> {
    let mut file = open(path, CREATE_NEW, false, 0, 0)?;
    file.write_all(text.as_bytes()).and_then(|_| file.sync_all()).map_err(|e| e.to_string())
}
