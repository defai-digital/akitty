//! Local transfer media for the Kitty graphics protocol: `t=f` files, `t=t`
//! temp files and `t=s` POSIX shared memory. The readers enforce Kitty's safety
//! rules and answer every failure with one fixed message that never echoes paths.

use std::ffi::CString;
use std::path::{Path, PathBuf};

/// The one error every media failure reports.
const BAD: &str = "EBADF:failed to read image data";
const MAX_PATH: usize = 4096;

fn bad<T>() -> Result<T, String> {
    Err(BAD.into())
}

/// Reads `size` bytes (0 = to EOF) from `offset` of a temp file the client
/// prepared. The path must be absolute, at most 4096 bytes without NUL, and
/// canonicalize to a regular file whose name mentions the protocol and that
/// lives under a temp directory; the file is unlinked after the read attempt
/// when it is still the inode that was opened.
pub fn read_temp_file(path: &[u8], offset: u64, size: u64, max: usize) -> Result<Vec<u8>, String> {
    if path.len() > MAX_PATH || path.contains(&0) { return bad(); }
    let Ok(text) = std::str::from_utf8(path) else { return bad(); };
    if !text.starts_with('/') { return bad(); }
    let Ok(canonical) = std::fs::canonicalize(text) else { return bad(); };
    if !canonical.file_name().is_some_and(|name| name.to_string_lossy().contains("tty-graphics-protocol")) { return bad(); }
    if !under_temp_dirs(&canonical) { return bad(); }
    let Ok(cpath) = CString::new(canonical.as_os_str().as_encoded_bytes()) else { return bad(); };
    // SAFETY: cpath is a valid NUL-terminated path; O_NONBLOCK keeps special files from blocking the open.
    let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOFOLLOW) };
    if fd < 0 { return bad(); }
    let mut opened: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: fd is an owned open descriptor.
    if unsafe { libc::fstat(fd, &mut opened) } != 0 {
        // SAFETY: fd is an owned open descriptor.
        let _ = unsafe { libc::close(fd) };
        return bad();
    }
    // Recheck the descriptor after opening: a renamed parent must not redirect
    // an accepted temporary path to a file outside the validated location.
    let allowed = opened_path(fd).is_some_and(|real| Path::new(&real) == canonical);
    let result = if allowed { read_fd(fd, &opened, offset, size, max) } else { bad() };
    // SAFETY: fd is an owned open descriptor.
    let _ = unsafe { libc::close(fd) };
    // Kitty deletes the temp file whether the read worked or not, but only
    // when the name still points at the inode that was opened.
    let mut now: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: cpath is a valid NUL-terminated path.
    if allowed && opened.st_mode & libc::S_IFMT == libc::S_IFREG
        && unsafe { libc::lstat(cpath.as_ptr(), &mut now) } == 0
        && now.st_dev == opened.st_dev
        && now.st_ino == opened.st_ino
    {
        let _ = std::fs::remove_file(&canonical);
    }
    result
}

/// Reads `size` bytes (0 = to EOF) from `offset` of a file the client names (`t=f`), as Kitty and Ghostty allow: the
/// path is absolute and the opened file is a regular file outside /dev, /proc and /sys. It is never deleted. The
/// blocklist is checked against the path of the opened descriptor, so a symlink swapped in after a check cannot
/// redirect the read.
pub fn read_file(path: &[u8], offset: u64, size: u64, max: usize) -> Result<Vec<u8>, String> {
    if path.len() > MAX_PATH || path.first() != Some(&b'/') { return bad(); }
    let Ok(cpath) = CString::new(path) else { return bad(); };
    // SAFETY: cpath is a valid NUL-terminated path; O_NONBLOCK keeps special files from blocking the open.
    let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC) };
    if fd < 0 { return bad(); }
    let allowed = opened_path(fd).is_some_and(|real| !["/dev/", "/proc/", "/sys/"].iter().any(|root| real.starts_with(root)));
    let mut opened: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: fd is an owned open descriptor.
    let result = if allowed && unsafe { libc::fstat(fd, &mut opened) } == 0 { read_fd(fd, &opened, offset, size, max) } else { bad() };
    // SAFETY: fd is an owned open descriptor.
    let _ = unsafe { libc::close(fd) };
    result
}

/// The path of an open descriptor as the kernel resolved it.
fn opened_path(fd: i32) -> Option<String> {
    let mut buf = [0 as libc::c_char; libc::PATH_MAX as usize];
    // SAFETY: F_GETPATH writes at most MAXPATHLEN (= PATH_MAX) bytes, NUL included, into buf.
    if unsafe { libc::fcntl(fd, libc::F_GETPATH, buf.as_mut_ptr()) } != 0 { return None; }
    // SAFETY: on success buf holds a NUL-terminated path.
    unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) }.to_str().ok().map(str::to_owned)
}

/// True when the path lies under a temp root: the environment's temp
/// directory or the platform's, each canonicalized so symlinked roots
/// (e.g. /tmp -> /private/tmp) still match.
fn under_temp_dirs(canonical: &Path) -> bool {
    let mut roots: Vec<PathBuf> = Vec::new();
    for root in [
        std::env::temp_dir(),
        PathBuf::from("/tmp"),
        PathBuf::from("/private/tmp"),
        PathBuf::from("/var/folders"),
        PathBuf::from("/private/var/folders"),
    ] {
        if root == Path::new("/") { continue; }
        if let Ok(resolved) = std::fs::canonicalize(&root) && !roots.contains(&resolved) {
            roots.push(resolved);
        }
    }
    roots.iter().any(|root| canonical.starts_with(root))
}

/// Bounds-checks one opened regular file against the request and reads it.
fn read_fd(fd: i32, opened: &libc::stat, offset: u64, size: u64, max: usize) -> Result<Vec<u8>, String> {
    if opened.st_mode & libc::S_IFMT != libc::S_IFREG || opened.st_size < 0 { return bad(); }
    let length = opened.st_size as u64;
    if offset > length { return bad(); }
    let want = if size == 0 { length - offset } else { size };
    if want > max as u64 || offset.checked_add(want).is_none_or(|end| end > length) {
        return bad();
    }
    read_slice(fd, offset, want)
}

/// Reads `want` bytes starting at `offset` from an owned descriptor.
fn read_slice(fd: i32, offset: u64, want: u64) -> Result<Vec<u8>, String> {
    let mut out = vec![0u8; want as usize];
    let mut done = 0usize;
    while done < out.len() {
        // SAFETY: out is writable for the remaining bytes; fd stays open for the loop.
        let got = unsafe {
            libc::pread(fd, out[done..].as_mut_ptr().cast(), out.len() - done, (offset + done as u64) as libc::off_t)
        };
        if got < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted { continue; }
            return bad();
        }
        if got == 0 { return bad(); }
        done += got as usize;
    }
    Ok(out)
}

/// Reads `size` bytes (0 = the whole object, which macOS reports page-rounded)
/// from `offset` of a POSIX shared memory object, then unlinks the name as the
/// protocol requires. Names are 1..=250 bytes, start with `/` and contain no
/// other slash and no NUL.
pub fn read_shared_memory(name: &[u8], offset: u64, size: u64, max: usize) -> Result<Vec<u8>, String> {
    if name.is_empty() || name.len() > 250 || name[0] != b'/' || name[1..].contains(&b'/') {
        return bad();
    }
    let Ok(cname) = CString::new(name) else { return bad(); };
    // SAFETY: cname is a valid NUL-terminated shared memory object name.
    let fd = unsafe { libc::shm_open(cname.as_ptr(), libc::O_RDONLY, 0) };
    if fd < 0 { return bad(); }
    let result = shm_read(fd, offset, size, max);
    // SAFETY: fd is an owned shared memory descriptor.
    let _ = unsafe { libc::close(fd) };
    // The terminal consumes the object once it has been opened.
    // SAFETY: cname is a valid NUL-terminated name.
    let _ = unsafe { libc::shm_unlink(cname.as_ptr()) };
    result
}

/// Copies the requested window out of one mapped shared memory object.
fn shm_read(fd: i32, offset: u64, size: u64, max: usize) -> Result<Vec<u8>, String> {
    let mut opened: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: fd is an owned open descriptor.
    if unsafe { libc::fstat(fd, &mut opened) } != 0 || opened.st_size < 0 { return bad(); }
    let length = opened.st_size as u64;
    if offset > length { return bad(); }
    // macOS rounds the object size up to whole pages, so a read without `S=` takes at most what the format needs.
    let want = if size == 0 { (length - offset).min(max as u64) } else { size };
    if want > max as u64 || offset.checked_add(want).is_none_or(|end| end > length) {
        return bad();
    }
    if want == 0 { return Ok(Vec::new()); }
    let map_len = (offset + want) as usize;
    // SAFETY: fd is owned and readable; the length is bounded by the fstat size.
    let map = unsafe { libc::mmap(std::ptr::null_mut(), map_len, libc::PROT_READ, libc::MAP_SHARED, fd, 0) };
    if map == libc::MAP_FAILED { return bad(); }
    // SAFETY: the mapping holds map_len readable bytes for this scope; it is only copied from.
    let bytes = unsafe {
        std::slice::from_raw_parts(map.cast::<u8>().cast_const().wrapping_add(offset as usize), want as usize)
    }
    .to_vec();
    // SAFETY: map was a successful mmap of map_len bytes.
    unsafe { libc::munmap(map, map_len) };
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static SEED: AtomicU32 = AtomicU32::new(0);

    /// A unique marker-named path in the real temp directory.
    fn marker_path(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "tty-graphics-protocol-akitty-{tag}-{}-{}",
            std::process::id(),
            SEED.fetch_add(1, Ordering::Relaxed)
        ))
    }
    fn write_new(path: &Path, bytes: &[u8]) {
        std::fs::write(path, bytes).unwrap();
        assert!(path.exists());
    }

    #[test]
    fn temp_file_is_read_offset_bounded_and_deleted() {
        let path = marker_path("whole");
        write_new(&path, &(0..=255u8).collect::<Vec<u8>>());
        assert_eq!(read_temp_file(path.as_os_str().as_encoded_bytes(), 0, 0, 512).unwrap(), (0..=255u8).collect::<Vec<u8>>());
        assert!(!path.exists(), "the whole-file read consumes the file");

        let path = marker_path("window");
        write_new(&path, &[7u8; 300]);
        assert_eq!(read_temp_file(path.as_os_str().as_encoded_bytes(), 100, 50, 512).unwrap(), vec![7u8; 50]);
        assert!(!path.exists());

        // Bounds failures still consume an accepted file, so each gets a fresh one.
        let path = marker_path("over-max");
        write_new(&path, &[1u8; 64]);
        assert!(read_temp_file(path.as_os_str().as_encoded_bytes(), 0, 0, 16).is_err());
        assert!(!path.exists());
        let path = marker_path("past-eof");
        write_new(&path, &[1u8; 64]);
        assert!(read_temp_file(path.as_os_str().as_encoded_bytes(), 60, 32, 512).is_err());
        assert!(!path.exists());
        let path = marker_path("late-offset");
        write_new(&path, &[1u8; 64]);
        assert!(read_temp_file(path.as_os_str().as_encoded_bytes(), 65, 0, 512).is_err());
        assert!(!path.exists());
    }

    #[test]
    fn temp_marker_in_parent_directory_does_not_authorize_deleting_plain_file() {
        let dir = marker_path("parent");
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("keep.bin");
        write_new(&path, &[1, 2, 3, 4]);
        let result = read_temp_file(path.as_os_str().as_encoded_bytes(), 0, 0, 64);
        let retained = path.exists();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(result.is_err(), "only the file name may authorize consumption");
        assert!(retained, "unaccepted files must survive");
    }

    #[test]
    fn named_files_are_read_but_kept_and_devices_are_refused() {
        let path = marker_path("named");
        write_new(&path, &(0..32u8).collect::<Vec<u8>>());
        assert_eq!(read_file(path.as_os_str().as_encoded_bytes(), 8, 4, 64).unwrap(), [8, 9, 10, 11]);
        assert!(path.exists(), "t=f never deletes the file");
        assert!(read_file(path.as_os_str().as_encoded_bytes(), 0, 0, 16).is_err(), "bounded by the format");
        std::fs::remove_file(&path).unwrap();
        // A symlink to a device resolves to the device and is refused like the device itself.
        let link = marker_path("link");
        std::os::unix::fs::symlink("/dev/zero", &link).unwrap();
        assert!(read_file(link.as_os_str().as_encoded_bytes(), 0, 4, 64).is_err());
        std::fs::remove_file(&link).unwrap();
        for refused in [&b"/dev/zero"[..], b"/dev/null", b"relative/path", b"/", b""] {
            assert_eq!(read_file(refused, 0, 4, 64), Err(BAD.to_string()));
        }
    }

    #[test]
    fn refused_paths_are_not_deleted() {
        // Outside every temp root: the working directory of the test process.
        let outside = std::env::current_dir().unwrap().join("tty-graphics-protocol-akitty-outside");
        write_new(&outside, &[1u8; 8]);
        assert!(read_temp_file(outside.as_os_str().as_encoded_bytes(), 0, 0, 64).is_err());
        assert!(outside.exists(), "unaccepted paths keep their file");
        std::fs::remove_file(&outside).unwrap();

        // Inside the temp root but missing the marker name.
        let plain = std::env::temp_dir().join("akitty-plain-name");
        write_new(&plain, &[1u8; 8]);
        assert!(read_temp_file(plain.as_os_str().as_encoded_bytes(), 0, 0, 64).is_err());
        assert!(plain.exists());
        std::fs::remove_file(&plain).unwrap();

        // A relative path and junk bytes are refused without touching anything.
        assert!(read_temp_file(b"tty-graphics-protocol", 0, 0, 64).is_err());
        assert!(read_temp_file(b"\xff\xfe", 0, 0, 64).is_err());
        assert!(read_temp_file(b"/tmp/\0tty-graphics-protocol", 0, 0, 64).is_err());

        // A symlink inside temp that resolves elsewhere fails the canonical check,
        // and the target survives untouched.
        let target = std::env::current_dir().unwrap().join("tty-graphics-protocol-akitty-target");
        write_new(&target, &[2u8; 8]);
        let link = marker_path("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(read_temp_file(link.as_os_str().as_encoded_bytes(), 0, 0, 64).is_err());
        assert!(target.exists() && link.exists());
        std::fs::remove_file(&link).unwrap();
        std::fs::remove_file(&target).unwrap();
    }

    #[test]
    fn fifos_directories_and_missing_files_are_refused() {
        let fifo = marker_path("fifo");
        let cfifo = CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: cfifo is a valid NUL-terminated path; creation only.
        assert_eq!(unsafe { libc::mkfifo(cfifo.as_ptr(), 0o600) }, 0);
        assert!(read_temp_file(fifo.as_os_str().as_encoded_bytes(), 0, 0, 64).is_err());
        let _ = std::fs::remove_file(&fifo);

        let dir = marker_path("dir");
        std::fs::create_dir(&dir).unwrap();
        assert!(read_temp_file(dir.as_os_str().as_encoded_bytes(), 0, 0, 64).is_err());
        std::fs::remove_dir(&dir).unwrap();

        let missing = marker_path("missing");
        assert!(read_temp_file(missing.as_os_str().as_encoded_bytes(), 0, 0, 64).is_err());
        assert!(!missing.exists());
    }

    /// Creates a shared memory object with the given payload.
    fn shm_create(name: &str, bytes: &[u8]) {
        let cname = CString::new(name).unwrap();
        // SAFETY: cname is a valid NUL-terminated name; the fd is closed here.
        let fd = unsafe { libc::shm_open(cname.as_ptr(), libc::O_CREAT | libc::O_RDWR, 0o600) };
        assert!(fd >= 0);
        // SAFETY: fd is owned and sized to the payload before it is mapped; macOS shared memory objects cannot be
        // written with write(2), so the payload goes in through a mapping, as Kitty clients do.
        unsafe {
            assert_eq!(libc::ftruncate(fd, bytes.len() as libc::off_t), 0);
            let map = libc::mmap(std::ptr::null_mut(), bytes.len(), libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, 0);
            assert_ne!(map, libc::MAP_FAILED);
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), map.cast::<u8>(), bytes.len());
            libc::munmap(map, bytes.len());
            libc::close(fd);
        }
    }
    fn shm_name(tag: &str) -> String {
        format!("/akitty-shm-{}-{tag}-{}", std::process::id(), SEED.fetch_add(1, Ordering::Relaxed))
    }

    #[test]
    fn shared_memory_round_trips_and_is_unlinked() {
        let name = shm_name("whole");
        shm_create(&name, &[9u8; 300]);
        // macOS reports the page-rounded size, so a zero size reads up to the bound.
        let read = read_shared_memory(name.as_bytes(), 0, 0, 8192).unwrap();
        assert!(read.len() >= 300 && read[..300] == [9u8; 300]);
        let cname = CString::new(name.as_bytes()).unwrap();
        // SAFETY: cname is a valid NUL-terminated name of a consumed object.
        assert!(unsafe { libc::shm_open(cname.as_ptr(), libc::O_RDONLY, 0) } < 0, "unlinked after the read");

        let name = shm_name("exact");
        shm_create(&name, &(0..200u8).collect::<Vec<u8>>());
        assert_eq!(
            read_shared_memory(name.as_bytes(), 0, 200, 512).unwrap(),
            (0..200u8).collect::<Vec<u8>>()
        );
        let name = shm_name("window");
        shm_create(&name, &(0..200u8).collect::<Vec<u8>>());
        assert_eq!(
            read_shared_memory(name.as_bytes(), 40, 60, 512).unwrap(),
            (40..100u8).collect::<Vec<u8>>()
        );

        // Bounds failures still consume an opened object.
        let name = shm_name("over-max");
        shm_create(&name, &[3u8; 128]);
        assert!(read_shared_memory(name.as_bytes(), 0, 128, 16).is_err());
        let cname = CString::new(name.as_bytes()).unwrap();
        assert!(unsafe { libc::shm_open(cname.as_ptr(), libc::O_RDONLY, 0) } < 0);
    }

    #[test]
    fn bad_shared_memory_names_and_missing_objects_are_refused() {
        assert!(read_shared_memory(b"noleadingslash", 0, 0, 8).is_err());
        assert!(read_shared_memory(b"", 0, 0, 8).is_err());
        assert!(read_shared_memory(b"/two/slashes", 0, 0, 8).is_err());
        assert!(read_shared_memory(format!("/{}", "n".repeat(250)).as_bytes(), 0, 0, 8).is_err());
        assert!(read_shared_memory(b"/\0nul", 0, 0, 8).is_err());
        assert!(read_shared_memory(b"/akitty-shm-absent", 0, 0, 8).is_err());
    }
}
