use crate::child::{ChildGuard, ChildSlot};
use crate::model::{Model, Size};
use alacritty_terminal::grid::Scroll;
use alacritty_terminal::index::{Column, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::term::{TermMode, viewport_to_point};
use portable_pty::{CommandBuilder, PtySize};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};

const MAX_PENDING: usize = 1_048_576;
enum Command {
    Input(Vec<u8>),
    Resize(Size),
}
pub struct Session {
    model: Arc<Mutex<Model>>,
    commands: Option<mpsc::SyncSender<Command>>,
    stop: Arc<AtomicBool>,
    pending: Arc<AtomicUsize>,
    worker: Mutex<Option<JoinHandle<Result<(), String>>>>,
}
impl Session {
    pub fn new(
        cols: usize,
        rows: usize,
        shell: Option<String>,
        cwd: Option<String>,
        headless: bool,
        scrollback: usize,
        shell_integration_dir: Option<String>,
    ) -> Result<Self, String> {
        if scrollback > 20000 { return Err("scrollback exceeds 20000 lines".into()); }
        let size = Size::validate(cols, rows)?;
        let model = Arc::new(Mutex::new(Model::new(size, scrollback)));
        let stop = Arc::new(AtomicBool::new(false));
        let pending = Arc::new(AtomicUsize::new(0));
        if headless {
            return Ok(Self {
                model,
                commands: None,
                stop,
                pending,
                worker: Mutex::new(None),
            });
        }
        let shell = shell
            .or_else(|| std::env::var("SHELL").ok())
            .unwrap_or_else(|| "/bin/zsh".into());
        if !std::path::Path::new(&shell).is_absolute() {
            return Err("shell must be an absolute executable path".into());
        }
        let cwd = cwd
            .or_else(|| std::env::var("HOME").ok())
            .unwrap_or_else(|| "/".into());
        if !std::path::Path::new(&cwd).is_dir() {
            return Err("working directory does not exist".into());
        }
        let slot = ChildSlot::reserve()?;
        let pty = portable_pty::native_pty_system()
            .openpty(pty_size(size, (0, 0)))
            .map_err(|e| e.to_string())?;
        let fd = pty.master.as_raw_fd().ok_or("PTY has no file descriptor")?;
        // SAFETY: fd is owned by pty.master, which outlives the worker.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let mut cmd = CommandBuilder::new(&shell);
        if let Some(directory) = shell_integration_dir {
            if directory.len() > 4096 || !std::path::Path::new(&directory).is_absolute() {
                return Err("shell integration directory must be an absolute path of at most 4096 bytes".into());
            }
            let root = std::path::Path::new(&directory);
            let name = std::path::Path::new(&shell).file_name().and_then(|n|n.to_str()).unwrap_or("");
            let resource = match name { "bash" => "bashrc", "zsh" => ".zshrc", _ => return Err("shell integration supports bash and zsh only".into()) };
            if !root.join(resource).is_file() { return Err("shell integration resources missing".into()); }
            cmd.env("AKITTY_INTEGRATION_DIR", &directory);
            if name == "bash" { cmd.args(["--rcfile", &root.join("bashrc").to_string_lossy(), "-i"]); }
            else {
                cmd.env("AKITTY_USER_ZDOTDIR", std::env::var("ZDOTDIR").or_else(|_|std::env::var("HOME")).unwrap_or_else(|_|"/".into()));
                cmd.env("ZDOTDIR", &directory); cmd.args(["-l", "-i"]);
            }
        } else { cmd.arg("-l"); }
        cmd.cwd(cwd);
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env("TERM_PROGRAM", "Akitty");
        cmd.env("TERM_PROGRAM_VERSION", env!("CARGO_PKG_VERSION"));
        let child = pty.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
        drop(pty.slave);
        let child = ChildGuard::new(child, fd, slot);
        let (tx, rx) = mpsc::sync_channel(4096);
        let model_worker = model.clone();
        let stop_worker = stop.clone();
        let pending_worker = pending.clone();
        let worker = thread::Builder::new()
            .name("akitty-pty".into())
            .spawn(move || {
                run(
                    pty.master,
                    child,
                    rx,
                    model_worker,
                    stop_worker,
                    pending_worker,
                )
            })
            .map_err(|e| e.to_string())?;
        Ok(Self {
            model,
            commands: Some(tx),
            stop,
            pending,
            worker: Mutex::new(Some(worker)),
        })
    }
    /// Snapshot JSON, already serialized; see [`Model::snapshot_json`].
    pub fn snapshot(&self, since: Option<u64>, compact: bool) -> Result<String, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        // Real PTY sessions expire in the worker, which owns delivery of replies.
        if self.commands.is_none() { model.expire_sync(); }
        model.snapshot_json(since, compact)
    }
    pub fn command_history(&self, after: u64) -> Result<Value, String> {
        Ok(self.model.lock().map_err(|_| "terminal unavailable")?.shell.history(after))
    }
    pub fn command_output(&self, id: u64) -> Result<Value, String> {
        self.model.lock().map_err(|_| "terminal unavailable")?.shell.command_output(id)
    }
    pub fn feed(&self, bytes: &[u8]) -> Result<(), String> {
        if self.commands.is_some() {
            return Err("feed is only available on headless sessions".into());
        }
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        for chunk in bytes.chunks(8192) {
            model.feed(chunk);
        }
        Ok(())
    }
    pub fn input(&self, text: String, paste: bool) -> Result<(), String> {
        if text.len() > 65536 {
            return Err("input exceeds 64 KiB".into());
        }
        let model = self.model.lock().map_err(|_| "terminal unavailable")?;
        if model.exited {
            return Err("shell has exited".into());
        }
        let bytes = if paste && model.term.mode().contains(TermMode::BRACKETED_PASTE) {
            // Prevent pasted escape characters from terminating the bracketed paste.
            format!("\x1b[200~{}\x1b[201~", text.replace('\x1b', "")).into_bytes()
        } else {
            text.into_bytes()
        };
        drop(model);
        self.input_bytes(bytes)
    }
    pub fn input_bytes(&self, bytes: Vec<u8>) -> Result<(), String> {
        if bytes.len() > 65548 { return Err("input exceeds 64 KiB plus paste delimiters".into()); }
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        if model.exited || self.stop.load(Ordering::SeqCst) { return Err("shell has exited".into()); }
        let previous_dirty = model.control.dirty;
        let checked = model.control.human_input(); model.revision += 1; checked?;
        if let Err(error) = self.enqueue_input(bytes) { model.control.dirty = previous_dirty; return Err(error); }
        model.term.scroll_display(Scroll::Bottom); model.revision += 1;
        Ok(())
    }
    fn enqueue_input(&self, bytes: Vec<u8>) -> Result<(), String> {
        let sender = self
            .commands
            .as_ref()
            .ok_or("headless session has no PTY")?;
        let len = bytes.len();
        if len == 0 {
            return Ok(());
        }
        self.pending
            .try_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                n.checked_add(len).filter(|&n| n <= MAX_PENDING)
            })
            .map_err(|_| "PTY input backpressure limit")?;
        if let Err(error) = sender.try_send(Command::Input(bytes)) {
            self.pending.fetch_sub(len, Ordering::SeqCst);
            return Err(format!("PTY command rejected: {error}"));
        }
        Ok(())
    }
    pub fn control_acquire(&self, actor: String) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        if model.exited { return Err("shell has exited".into()); }
        let result = model.control.acquire(actor); model.revision += 1; result
    }
    pub fn control_release(&self, lease: Option<u64>) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        let result = model.control.release(lease); model.revision += 1; result
    }
    pub fn command_authorize(&self, lease: u64, command: String, expected_cwd: Option<String>) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        if model.exited || !model.shell.ready || model.control.dirty { return Err("command requires an unedited integrated shell prompt".into()); }
        let cwd = model.shell.cwd.clone();
        if cwd != expected_cwd { return Err("working directory changed since approval request".into()); }
        let result = model.control.authorize(lease,command,cwd); model.revision += 1; result
    }
    pub fn command_deny(&self, lease: u64) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        let result = model.control.deny(lease); model.revision += 1; result
    }
    pub fn command_execute(&self, lease: u64, authorization: u64, command: String) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        let cwd = model.shell.cwd.clone();
        // Consume even on readiness or queue failure: retry always needs fresh approval.
        let consumed = model.control.consume(lease,authorization,&command,&cwd); model.revision += 1; consumed?;
        if model.exited || !model.shell.ready || model.control.dirty {
            model.control.record("dispatch_failed",None); return Err("command requires an unedited integrated shell prompt".into());
        }
        if let Err(error) = self.enqueue_input(format!("{command}\r").into_bytes()) {
            model.control.record("dispatch_failed",None); return Err(error);
        }
        model.shell.ready = false; model.control.dirty = true; model.revision += 1;
        Ok(json!({"accepted":true,"after_command_id":model.shell.summary()["last_command_id"],"completion_untrusted":true}))
    }
    pub fn control_audit(&self, after: u64) -> Result<Value, String> {
        Ok(self.model.lock().map_err(|_| "terminal unavailable")?.control.audit(after))
    }
    pub fn resize(&self, cols: usize, rows: usize) -> Result<(), String> {
        let size = Size::validate(cols, rows)?;
        if let Some(sender) = &self.commands {
            sender
                .try_send(Command::Resize(size))
                .map_err(|e| format!("resize rejected: {e}"))?;
        } else {
            let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
            model.term.resize(size);
            model.size = size;
            model.revision += 1;
        }
        Ok(())
    }
    pub fn set_cell_size(&self, width: u32, height: u32) -> Result<(), String> {
        if !(1..=256).contains(&width) || !(1..=512).contains(&height) {
            return Err("cell size must be 1..256 by 1..512 pixels".into());
        }
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        let previous = model.cell_px;
        let size = model.size;
        model.cell_px = (width, height);
        // Push a PTY resize so TIOCGWINSZ reports the new pixel size even
        // though the grid itself did not change. Headless sessions just store it.
        if let Some(sender) = &self.commands
            && let Err(error) = sender.try_send(Command::Resize(size))
        {
            // The PTY did not accept the resize, so keep the grid's geometry
            // consistent: restore the old pixel size and leave the revision alone.
            model.cell_px = previous;
            return Err(format!("resize rejected: {error}"));
        }
        // Placeholder geometry is derived from cell_px, so a successful change must
        // invalidate snapshots a client could otherwise serve from its cached revision.
        model.revision += 1;
        Ok(())
    }
    pub fn read_image(&self, image: u32, out: &mut [u8]) -> usize {
        let Ok(model) = self.model.lock() else { return 0 };
        match model.graphics.images.get(&image) {
            Some(found) if found.rgba.len() <= out.len() => {
                out[..found.rgba.len()].copy_from_slice(&found.rgba);
                found.rgba.len()
            }
            _ => 0,
        }
    }
    pub fn scroll(&self, lines: i32) -> Result<(), String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        model
            .term
            .scroll_display(Scroll::Delta(lines.clamp(-5000, 5000)));
        model.revision += 1;
        Ok(())
    }
    pub fn select(&self, sr: usize, sc: usize, er: usize, ec: usize) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        if sr >= model.size.rows
            || er >= model.size.rows
            || sc >= model.size.cols
            || ec >= model.size.cols
        {
            return Err("selection outside viewport".into());
        }
        let offset = model.term.grid().display_offset();
        let start = viewport_to_point(offset, Point::new(sr, Column(sc)));
        let end = viewport_to_point(offset, Point::new(er, Column(ec)));
        let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
        selection.update(end, Side::Right);
        model.term.selection = Some(selection);
        model.revision += 1;
        Ok(json!({"text": model.term.selection_to_string().unwrap_or_default()}))
    }
    pub fn find(&self, text: &str, direction: Option<&str>, clear: bool) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        if clear {
            if model.find.take().is_some() {
                model.revision = model.revision.saturating_add(1);
            }
            return Ok(json!({"found": false}));
        }
        if text.is_empty() || text.len() > 256 {
            return Err("search must contain 1..256 bytes".into());
        }
        let direction = match direction {
            None | Some("latest") => crate::model::FindDirection::Latest,
            Some("next") => crate::model::FindDirection::Next,
            Some("previous") => crate::model::FindDirection::Previous,
            Some(_) => return Err("unknown find direction".into()),
        };
        Ok(model.search(text, direction))
    }
    pub fn set_chrome(&self, input: crate::chrome::ChromeInput) -> Result<(), String> {
        self.model.lock().map_err(|_| "terminal unavailable")?.set_chrome(input)
    }
    pub fn set_program_chrome(&self, enabled: bool) -> Result<(), String> {
        self.model.lock().map_err(|_| "terminal unavailable")?.set_program_chrome(enabled);
        Ok(())
    }
    pub fn close(&self) -> Result<(), String> {
        self.shutdown()
    }
    fn shutdown(&self) -> Result<(), String> {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self
            .worker
            .lock()
            .map_err(|_| "worker cleanup unavailable")?
            .take()
        {
            worker.join().map_err(|_| "PTY worker panicked")??;
        }
        Ok(())
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}
fn pty_size(s: Size, cell: (u32, u32)) -> PtySize {
    PtySize {
        cols: s.cols as u16,
        rows: s.rows as u16,
        // Device pixels of the window: cells times cell size, clamped to u16.
        pixel_width: (s.cols * cell.0 as usize).min(u16::MAX as usize) as u16,
        pixel_height: (s.rows * cell.1 as usize).min(u16::MAX as usize) as u16,
    }
}

/// Retry interruptions/readiness races; preserve unexpected failures for session status.
fn read_pty(fd: i32, buffer: &mut [u8], hung_up: bool) -> Result<Option<usize>, String> {
    // SAFETY: buffer is writable for its length; read reports invalid descriptors as EBADF.
    let count = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
    if count >= 0 { return Ok(Some(count as usize)); }
    let error = std::io::Error::last_os_error();
    if matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) {
        return Ok(None);
    }
    // Some PTYs report EIO on hangup; only an observed hangup authorizes normal EOF.
    if hung_up && error.raw_os_error() == Some(libc::EIO) { return Ok(Some(0)); }
    Err(format!("PTY read failed: {error}"))
}

fn run(
    master: Box<dyn portable_pty::MasterPty + Send>,
    mut child: ChildGuard,
    rx: mpsc::Receiver<Command>,
    model: Arc<Mutex<Model>>,
    stop: Arc<AtomicBool>,
    pending: Arc<AtomicUsize>,
) -> Result<(), String> {
    let fd = master.as_raw_fd().ok_or("PTY descriptor missing")?;
    let mut output: VecDeque<(Vec<u8>, usize, bool)> = VecDeque::new();
    let mut response_pending = 0usize;
    let mut buffer = [0u8; 8192];
    let mut io_error = None;
    while !stop.load(Ordering::SeqCst) {
        let replies = model.lock().map_err(|_| "terminal state poisoned")?.expire_sync();
        if !replies.is_empty() {
            response_pending += replies.len();
            if response_pending > 65536 {
                io_error = Some("terminal response backpressure limit".into());
                break;
            }
            output.push_back((replies, 0, false));
        }
        for command in rx.try_iter().take(16) {
            match command {
                Command::Input(bytes) => output.push_back((bytes, 0, true)),
                Command::Resize(size) => {
                    // The cell size is read before the ioctl so TIOCGWINSZ sees it.
                    let cell = model.lock().map(|state| state.cell_px).unwrap_or((0, 0));
                    if let Err(error) = master.resize(pty_size(size, cell)) {
                        io_error = Some(error.to_string());
                        break;
                    }
                    if let Ok(mut state) = model.lock() {
                        state.term.resize(size);
                        state.size = size;
                        state.revision += 1;
                    }
                }
            }
        }
        if io_error.is_some() {
            break;
        }
        let mut poll = libc::pollfd {
            fd,
            events: libc::POLLIN | if output.is_empty() { 0 } else { libc::POLLOUT },
            revents: 0,
        };
        // SAFETY: poll references one valid pollfd for this owned master.
        let ready = unsafe { libc::poll(&mut poll, 1, 10) };
        if ready < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            io_error = Some(std::io::Error::last_os_error().to_string());
            break;
        }
        if poll.revents & libc::POLLOUT != 0
            && let Some((bytes, offset, counted)) = output.front_mut()
        {
            let slice = &bytes[*offset..];
            // SAFETY: byte slice is valid for its length, fd remains owned.
            let written = unsafe { libc::write(fd, slice.as_ptr().cast(), slice.len()) };
            if written > 0 {
                *offset += written as usize;
                if *counted {
                    pending.fetch_sub(written as usize, Ordering::SeqCst);
                } else {
                    response_pending -= written as usize;
                }
                if *offset == bytes.len() {
                    output.pop_front();
                }
            } else if written < 0 {
                let error = std::io::Error::last_os_error();
                if !matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) {
                    io_error = Some(error.to_string());
                    break;
                }
            }
        }
        if poll.revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            match read_pty(fd, &mut buffer, poll.revents & libc::POLLHUP != 0) {
                Ok(Some(0)) => break,
                Ok(Some(count)) => {
                    let mut state = model.lock().map_err(|_| "terminal state poisoned")?;
                    let replies = state.feed(&buffer[..count]);
                    if !replies.is_empty() {
                        response_pending += replies.len();
                        if response_pending > 65536 {
                            io_error = Some("terminal response backpressure limit".into());
                            break;
                        }
                        output.push_back((replies, 0, false));
                    }
                }
                Ok(None) => {},
                Err(error) => { io_error = Some(error); break; },
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                if let Ok(mut state) = model.lock() {
                    state.exited = true;
                    state.exit_code = Some(status.exit_code());
                    state.revision += 1;
                }
                // Drain available final output without waiting for inherited slave FDs.
                // A descendant can keep the slave writable after shell exit.
                // Bound this drain so close never joins an endless reader.
                for _ in 0..32 {
                    if stop.load(Ordering::SeqCst) {
                        break;
                    }
                    match read_pty(fd, &mut buffer, true) {
                        Ok(Some(0)) | Ok(None) => break,
                        Ok(Some(count)) => {
                            if let Ok(mut state) = model.lock() { state.feed(&buffer[..count]); }
                        }
                        Err(error) => { io_error = Some(error); break; },
                    }
                }
                break;
            }
            Ok(None) => {}
            Err(error) => {
                io_error = Some(error.to_string());
                break;
            }
        }
    }
    if let Err(error) = child.finish()
        && io_error.is_none()
    {
        io_error = Some(error);
    }
    if let Ok(mut state) = model.lock() {
        state.shell.finish();
        state.exited = true;
        state.exit_code = child.exit_code();
        state.error = io_error.clone();
        state.revision += 1;
    }
    drop(master);
    if let Some(error) = io_error {
        Err(error)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unexpected_pty_read_failure_is_preserved_even_with_hangup() {
        for hung_up in [false, true] {
            let error = read_pty(-1, &mut [0; 8], hung_up).unwrap_err();
            assert!(error.starts_with("PTY read failed:"), "{error}");
            assert!(error.contains(&std::io::Error::from_raw_os_error(libc::EBADF).to_string()));
        }
    }

    #[test]
    fn input_backpressure_bounds_bytes_and_rolls_back_rejected_messages() {
        let mut session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (tx, rx) = mpsc::sync_channel(1);
        session.commands = Some(tx);
        session.input_bytes(vec![0xff; 65536]).unwrap();
        assert_eq!(session.pending.load(Ordering::SeqCst), 65536);
        assert!(session.input_bytes(vec![1; 100]).is_err());
        assert_eq!(session.pending.load(Ordering::SeqCst), 65536);
        assert!(matches!(rx.recv().unwrap(), Command::Input(bytes) if bytes == vec![0xff; 65536]));
        session.pending.store(MAX_PENDING, Ordering::SeqCst);
        assert!(session.input_bytes(vec![1]).is_err());
        assert_eq!(session.pending.load(Ordering::SeqCst), MAX_PENDING);
        assert!(session.input_bytes(vec![1; 65549]).is_err());
        session.close().unwrap();
        assert!(session.input_bytes(vec![1]).is_err());
    }

    #[test]
    fn pty_pixel_size_is_cells_times_cell_pixels_and_clamps() {
        let size = Size::validate(80, 24).unwrap();
        let unknown = pty_size(size, (0, 0));
        assert_eq!((unknown.pixel_width, unknown.pixel_height), (0, 0));
        let pty = pty_size(size, (10, 20));
        assert_eq!((pty.cols, pty.rows, pty.pixel_width, pty.pixel_height), (80, 24, 800, 480));
        let huge = pty_size(Size::validate(256, 128).unwrap(), (256, 512));
        assert_eq!((huge.pixel_width, huge.pixel_height), (u16::MAX, u16::MAX));
    }

    #[test]
    fn set_cell_size_pushes_a_pty_resize_without_a_grid_change() {
        let mut session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (tx, rx) = mpsc::sync_channel(1);
        session.commands = Some(tx);
        session.set_cell_size(10, 20).unwrap();
        assert!(
            matches!(rx.try_recv(), Ok(Command::Resize(size)) if (size.cols, size.rows) == (20, 3))
        );
        assert_eq!(session.model.lock().unwrap().cell_px, (10, 20));
    }

    #[test]
    fn set_cell_size_invalidates_the_snapshot_revision() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let first: Value = serde_json::from_str(&session.snapshot(None, true).unwrap()).unwrap();
        let since = first["revision"].as_u64();
        session.set_cell_size(10, 20).unwrap();
        let second: Value = serde_json::from_str(&session.snapshot(since, true).unwrap()).unwrap();
        // The new pixel size feeds placeholder geometry, so a same-revision poll must
        // still report a change instead of serving the stale placeholder layout.
        assert_eq!(second["changed"], true, "{second}");
        assert_eq!(session.model.lock().unwrap().cell_px, (10, 20));
    }

    #[test]
    fn rejected_cell_size_send_rolls_back_pixels_without_a_revision_bump() {
        let mut session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.set_cell_size(10, 20).unwrap();
        let revision = session.model.lock().unwrap().revision;
        // Fill the bounded command queue so the resize send is rejected.
        let (tx, rx) = mpsc::sync_channel(1);
        tx.try_send(Command::Input(vec![0])).unwrap();
        session.commands = Some(tx);
        let outcome = session.set_cell_size(12, 24);
        assert!(outcome.is_err(), "{outcome:?}");
        // A rejected resize must leave both the geometry and the revision untouched.
        let model = session.model.lock().unwrap();
        assert_eq!(model.cell_px, (10, 20));
        assert_eq!(model.revision, revision);
        drop(model);
        // The queued input is the only message; no resize followed it.
        assert!(matches!(rx.try_recv(), Ok(Command::Input(_))));
        assert!(rx.try_recv().is_err());
    }
}
