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
            let resource = match name { "bash" => "bashrc", "zsh" => ".zshenv", _ => return Err("shell integration supports bash and zsh only".into()) };
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
    /// Shell and control summaries without a snapshot's side effects: a snapshot consumes
    /// pending bell and clipboard events, so hosts must not take one just to read the cwd.
    pub fn shell_state(&self) -> Result<Value, String> {
        let model = self.model.lock().map_err(|_| "terminal unavailable")?;
        Ok(serde_json::json!({"shell": model.shell.summary(), "control": model.control.summary()}))
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
        // Zero bytes never reach the PTY, so the prompt was not edited: keep it authorizable
        // instead of leaving the dirty flag set by human_input behind.
        if bytes.is_empty() { model.control.dirty = previous_dirty; return self.enqueue_input(bytes); }
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
        let result = model.control.acquire(actor); if result.is_ok() { model.revision += 1; } result
    }
    pub fn control_release(&self, lease: Option<u64>) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        let result = model.control.release(lease); if result.is_ok() { model.revision += 1; } result
    }
    pub fn command_authorize(&self, lease: u64, command: String, expected_cwd: Option<String>) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        if model.exited || !model.shell.ready || model.control.dirty { return Err("command requires an unedited integrated shell prompt".into()); }
        let cwd = model.shell.cwd.clone();
        if cwd != expected_cwd { return Err("working directory changed since approval request".into()); }
        let seq = model.control.audit_seq();
        let result = model.control.authorize(lease,command,cwd);
        if result.is_ok() || model.control.audit_seq() != seq { model.revision += 1; }
        result
    }
    pub fn command_deny(&self, lease: u64) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        let result = model.control.deny(lease); if result.is_ok() { model.revision += 1; } result
    }
    pub fn command_execute(&self, lease: u64, authorization: u64, command: String) -> Result<Value, String> {
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        let cwd = model.shell.cwd.clone();
        // Consume even on readiness or queue failure: retry always needs fresh approval.
        // A rejected consume only invalidates the snapshot when it appended audit.
        let seq = model.control.audit_seq();
        let consumed = model.control.consume(lease,authorization,&command,&cwd);
        if consumed.is_ok() || model.control.audit_seq() != seq { model.revision += 1; }
        consumed?;
        if model.exited || !model.shell.ready || model.control.dirty {
            model.control.dispatch_failed(); return Err("command requires an unedited integrated shell prompt".into());
        }
        if let Err(error) = self.enqueue_input(format!("{command}\r").into_bytes()) {
            model.control.dispatch_failed(); return Err(error);
        }
        model.shell.ready = false; model.control.dirty = true; model.revision += 1;
        Ok(json!({"accepted":true,"after_command_id":model.shell.summary()["last_command_id"],"completion_untrusted":true}))
    }
    pub fn control_audit(&self, after: u64) -> Result<Value, String> {
        Ok(self.model.lock().map_err(|_| "terminal unavailable")?.control.audit(after))
    }
    pub fn resize(&self, cols: usize, rows: usize) -> Result<(), String> {
        let size = Size::validate(cols, rows)?;
        let mut model = self.model.lock().map_err(|_| "terminal unavailable")?;
        if let Some(sender) = &self.commands {
            // Record the grid before the send so a concurrent pixel-size push repeats
            // this request instead of the worker's still-stale applied size.
            let previous = model.requested_size;
            model.requested_size = size;
            if let Err(error) = sender.try_send(Command::Resize(size)) {
                model.requested_size = previous;
                return Err(format!("resize rejected: {error}"));
            }
        } else {
            model.term.resize(size);
            model.size = size;
            model.requested_size = size;
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
        // Repeat the latest queued grid, not the applied one, so a scale change cannot
        // re-send an older grid after the new resize the host already recorded.
        let size = model.requested_size;
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

const MAX_REPLY_BACKLOG: usize = 65_536;
const REPLY_BACKLOG_ERROR: &str = "terminal replies dropped: the program is not reading them";

/// Queues terminal replies (DSR, DA, ...) for the PTY. A program that floods queries without
/// reading the answers (e.g. `cat` of a captured log) must not take the session down, so once
/// the unread backlog reaches the cap new replies are dropped. Returns false when it dropped.
fn queue_replies(output: &mut VecDeque<(Vec<u8>, usize, bool)>, response_pending: &mut usize, replies: Vec<u8>) -> bool {
    if replies.is_empty() {
        return true;
    }
    if *response_pending + replies.len() > MAX_REPLY_BACKLOG {
        return false;
    }
    *response_pending += replies.len();
    output.push_back((replies, 0, false));
    true
}

/// Queue one parser batch and record a drop. The error has to become a new revision:
/// a host polling with the revision it already holds would otherwise get `changed:false`
/// and never learn that its program's queries went unanswered.
fn queue_parser_replies(
    state: &mut Model,
    output: &mut VecDeque<(Vec<u8>, usize, bool)>,
    response_pending: &mut usize,
    replies: Vec<u8>,
) {
    if queue_replies(output, response_pending, replies)
        || state.error.as_deref() == Some(REPLY_BACKLOG_ERROR)
    {
        return;
    }
    state.error = Some(REPLY_BACKLOG_ERROR.into());
    state.revision = state.revision.saturating_add(1);
}

/// Expire the parser deadline and queue its replies under one model lock, so a concurrent
/// feed cannot reset the backlog between the expiry and the drop decision.
fn expire_and_queue(
    model: &Arc<Mutex<Model>>,
    output: &mut VecDeque<(Vec<u8>, usize, bool)>,
    response_pending: &mut usize,
) -> Result<(), String> {
    let mut state = model.lock().map_err(|_| "terminal state poisoned")?;
    let replies = state.expire_sync();
    queue_parser_replies(&mut state, output, response_pending, replies);
    Ok(())
}

/// Feed terminal bytes and queue the replies they produced. The live loop and the post-exit
/// drain both go through here, so the last answers a program asked for before exiting are
/// not discarded with the parse result.
fn feed_and_queue(
    model: &Arc<Mutex<Model>>,
    output: &mut VecDeque<(Vec<u8>, usize, bool)>,
    response_pending: &mut usize,
    bytes: &[u8],
) -> Result<(), String> {
    let mut state = model.lock().map_err(|_| "terminal state poisoned")?;
    let replies = state.feed(bytes);
    queue_parser_replies(&mut state, output, response_pending, replies);
    Ok(())
}

/// Record final worker state. A clean shutdown keeps an error the host was already shown;
/// only a real IO failure replaces it.
fn finalize(model: &Arc<Mutex<Model>>, exit_code: Option<u32>, io_error: Option<&str>) -> Result<(), String> {
    let mut state = model.lock().map_err(|_| "terminal state poisoned")?;
    state.shell.finish();
    state.exited = true;
    state.exit_code = exit_code;
    if let Some(error) = io_error {
        state.error = Some(error.into());
    }
    state.revision = state.revision.saturating_add(1);
    Ok(())
}

/// Write the front queued buffer once. `Ok(true)` moved bytes (and popped the entry once it
/// was complete), `Ok(false)` could not progress yet, `Err` means it can never be written.
fn write_front(
    fd: i32,
    output: &mut VecDeque<(Vec<u8>, usize, bool)>,
    response_pending: &mut usize,
    pending: &AtomicUsize,
) -> Result<bool, String> {
    let Some((bytes, offset, counted)) = output.front_mut() else {
        return Ok(false);
    };
    let slice = &bytes[*offset..];
    // SAFETY: slice is valid for its length; fd is the owned master descriptor.
    let written = unsafe { libc::write(fd, slice.as_ptr().cast(), slice.len()) };
    if written > 0 {
        *offset += written as usize;
        if *counted {
            pending.fetch_sub(written as usize, Ordering::SeqCst);
        } else {
            *response_pending -= written as usize;
        }
        if *offset == bytes.len() {
            output.pop_front();
        }
        return Ok(true);
    }
    if written == 0 {
        return Ok(false);
    }
    let error = std::io::Error::last_os_error();
    if matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) {
        return Ok(false);
    }
    Err(error.to_string())
}

/// A blocked reply flush waits only a bounded number of consecutive polls. Successful writes
/// reset that budget, so every already queued reply can be delivered without a fixed count cap.
const FLUSH_POLL_MS: libc::c_int = 5;
const FLUSH_BLOCKED_PASSES: usize = 2;

/// How long the post-exit drain waits for a still-attached descendant, and how many windows it
/// may wait. The short window catches a query written just after the shell exits; once a reply
/// has actually been delivered, the longer settle window keeps the master open while the
/// descendant consumes it, which is what makes a post-exit reply observable at all.
const DRAIN_IDLE_MS: libc::c_int = 20;
const DRAIN_SETTLE_MS: libc::c_int = 100;
const DRAIN_IDLE_WAITS: usize = 2;

/// Best-effort bounded delivery of the parser replies still queued when the worker stops.
/// User input queued before the child exited is stale and never reaches a process that has
/// already exited; replies keep their original order. A reply that cannot be written because
/// the reader is gone ends the flush without turning a clean exit into a session error.
/// Returns whether any byte was actually written, so the drain only waits on a real delivery.
fn flush_replies(
    fd: i32,
    output: &mut VecDeque<(Vec<u8>, usize, bool)>,
    response_pending: &mut usize,
    pending: &AtomicUsize,
) -> bool {
    let mut blocked = 0usize;
    let mut delivered = false;
    loop {
        // Release the backpressure reservation of input the exited child can never read.
        while let Some(stale) = output
            .front()
            .and_then(|(bytes, offset, counted)| (*counted).then(|| bytes.len() - *offset))
        {
            pending.fetch_sub(stale, Ordering::SeqCst);
            output.pop_front();
        }
        if output.is_empty() {
            return delivered;
        }
        match write_front(fd, output, response_pending, pending) {
            Ok(true) => {
                delivered = true;
                blocked = 0;
            }
            Ok(false) => {
                blocked += 1;
                if blocked > FLUSH_BLOCKED_PASSES {
                    return delivered;
                }
                let mut poll = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
                // SAFETY: poll references one valid pollfd for the owned master descriptor.
                if unsafe { libc::poll(&mut poll, 1, FLUSH_POLL_MS) } <= 0 {
                    return delivered;
                }
            }
            Err(_) => return delivered,
        }
    }
}

/// Read the child's final output after it exits, or after the PTY reports a hangup that can
/// arrive before the exit is observed, and answer the queries it still contains.
/// `Some` is an IO failure to record. An explicit stop ends the drain without flushing, and a
/// descendant that keeps the slave open can never make this run past its bounds.
fn drain_after_exit(
    fd: i32,
    model: &Arc<Mutex<Model>>,
    output: &mut VecDeque<(Vec<u8>, usize, bool)>,
    response_pending: &mut usize,
    pending: &AtomicUsize,
    stop: &AtomicBool,
) -> Option<String> {
    let mut buffer = [0u8; 8192];
    let mut idle_waits = 0;
    let mut delivered = false;
    for _ in 0..32 {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        match read_pty(fd, &mut buffer, true) {
            Ok(Some(0)) => break,
            Ok(None) => {
                // Nothing buffered. A descendant that only noticed the shell exit may still be
                // writing its last query, so wait a short window instead of closing the master
                // on the first empty read. Once a reply has been delivered the descendant needs
                // a longer window to read it before the master disappears with the answer.
                idle_waits += 1;
                if idle_waits > DRAIN_IDLE_WAITS {
                    break;
                }
                let wait = if delivered { DRAIN_SETTLE_MS } else { DRAIN_IDLE_MS };
                let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
                // SAFETY: poll references one valid pollfd for this owned master.
                if unsafe { libc::poll(&mut poll, 1, wait) } <= 0 {
                    break;
                }
            }
            Ok(Some(count)) => {
                idle_waits = 0;
                if let Err(error) = feed_and_queue(model, output, response_pending, &buffer[..count]) {
                    return Some(error);
                }
                // The live loop will not run again, so a query answered here only reaches the
                // program if the drain writes it before the master closes.
                delivered |= flush_replies(fd, output, response_pending, pending);
            }
            Err(error) => return Some(error),
        }
    }
    None
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
        expire_and_queue(&model, &mut output, &mut response_pending)?;
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
            && let Err(error) = write_front(fd, &mut output, &mut response_pending, &pending)
        {
            io_error = Some(error);
            break;
        }
        if poll.revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            match read_pty(fd, &mut buffer, poll.revents & libc::POLLHUP != 0) {
                Ok(Some(0)) => {
                    // A hangup can report EOF before try_wait sees the exit, so leaving here
                    // without draining would drop a query the program sent as it died. The
                    // post-loop flush still delivers whatever this drain queues.
                    if let Some(error) = drain_after_exit(fd, &model, &mut output, &mut response_pending, &pending, &stop) {
                        io_error = Some(error);
                    }
                    break;
                }
                Ok(Some(count)) => {
                    feed_and_queue(&model, &mut output, &mut response_pending, &buffer[..count])?;
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
                if let Some(error) = drain_after_exit(fd, &model, &mut output, &mut response_pending, &pending, &stop) {
                    io_error = Some(error);
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
    // Deliver what the drain queued before the master closes; this also covers an EOF break.
    // An explicit stop/close tears the session down, so it does not flush. The delivery result
    // only feeds the drain's settle decision, so it is discarded here.
    if !stop.load(Ordering::SeqCst) {
        let _ = flush_replies(fd, &mut output, &mut response_pending, &pending);
    }
    if let Err(error) = child.finish()
        && io_error.is_none()
    {
        io_error = Some(error);
    }
    let _ = finalize(&model, child.exit_code(), io_error.as_deref());
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
    fn empty_input_leaves_the_integrated_prompt_authorizable() {
        let mut session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        // A headless model with a fake PTY queue behaves like a live shell prompt.
        let (tx, rx) = mpsc::sync_channel(1);
        session.commands = Some(tx);
        session.input(String::new(), false).unwrap();
        session.input_bytes(Vec::new()).unwrap();
        assert!(rx.try_recv().is_err(), "empty input must not reach the PTY");
        assert!(!session.model.lock().unwrap().control.dirty, "empty input must not edit the prompt");
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        session.command_authorize(lease, "echo hi".into(), None).unwrap();
        session.control_release(Some(lease)).unwrap();
        // Real bytes still edit the prompt, so the guard stays effective.
        session.input_bytes(b"x".to_vec()).unwrap();
        assert!(session.model.lock().unwrap().control.dirty);
        assert!(matches!(rx.try_recv(), Ok(Command::Input(bytes)) if bytes == b"x"));
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        assert!(session.command_authorize(lease, "echo hi".into(), None).is_err());
    }

    #[test]
    fn empty_input_still_reports_headless_and_leased_prompts() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        // Without a PTY even an empty payload keeps the existing transport error.
        assert_eq!(session.input_bytes(Vec::new()).unwrap_err(), "headless session has no PTY");
        assert!(!session.model.lock().unwrap().control.dirty);
        // An agent-controlled prompt still rejects human typing, empty or not.
        let _lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let error = session.input_bytes(Vec::new()).unwrap_err();
        assert!(error.contains("agent controls this terminal"), "{error}");
        assert!(!session.model.lock().unwrap().control.dirty);
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
    fn cell_size_repeats_the_requested_grid_while_a_resize_is_still_queued() {
        let mut session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (tx, rx) = mpsc::sync_channel(2);
        session.commands = Some(tx);
        // The grid resize is only queued; the worker has not applied it to model.size yet.
        session.resize(30, 5).unwrap();
        // A scale change then re-sends the cell size, which must repeat the queued grid.
        session.set_cell_size(10, 20).unwrap();
        assert!(matches!(rx.try_recv(), Ok(Command::Resize(size)) if (size.cols, size.rows) == (30, 5)));
        assert!(matches!(rx.try_recv(), Ok(Command::Resize(size)) if (size.cols, size.rows) == (30, 5)));
        assert!(rx.try_recv().is_err());
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

    #[test]
    fn rejected_queue_dispatch_never_reports_a_shell_completion() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let authorization = session.command_authorize(lease, "echo hi".into(), None).unwrap()["authorization"].as_u64().unwrap();
        // A headless session has no PTY, so the grant is consumed and then the queue rejects it.
        assert!(session.command_execute(lease, authorization, "echo hi".into()).is_err());
        // An unrelated completion report must not be attributed to the rejected command.
        session.feed(b"\x1b]133;D\x07").unwrap();
        let audit = session.control_audit(0).unwrap();
        let events: Vec<&str> = audit["events"].as_array().unwrap().iter().filter_map(|e| e["event"].as_str()).collect();
        assert!(events.contains(&"dispatched"), "{audit}");
        assert!(events.contains(&"dispatch_failed"), "{audit}");
        assert!(!events.contains(&"shell_completion_observed_untrusted"), "{audit}");
    }

    #[test]
    fn rejected_readiness_dispatch_never_reports_a_shell_completion() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let authorization = session.command_authorize(lease, "echo hi".into(), None).unwrap()["authorization"].as_u64().unwrap();
        // The prompt left while the grant was pending, so consume succeeds and dispatch is refused.
        session.model.lock().unwrap().shell.ready = false;
        assert!(session.command_execute(lease, authorization, "echo hi".into()).is_err());
        session.feed(b"\x1b]133;D\x07").unwrap();
        let audit = session.control_audit(0).unwrap();
        let events: Vec<&str> = audit["events"].as_array().unwrap().iter().filter_map(|e| e["event"].as_str()).collect();
        assert!(events.contains(&"dispatch_failed"), "{audit}");
        assert!(!events.contains(&"shell_completion_observed_untrusted"), "{audit}");
    }

    #[test]
    fn rejected_control_operations_leave_the_snapshot_revision_unchanged() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let first: Value = serde_json::from_str(&session.snapshot(None, true).unwrap()).unwrap();
        let since = first["revision"].as_u64();
        let unchanged = |session: &Session| {
            let snapshot: Value = serde_json::from_str(&session.snapshot(since, true).unwrap()).unwrap();
            assert_eq!(snapshot["changed"], false, "{snapshot}");
        };
        assert!(session.control_acquire("second".into()).is_err());
        unchanged(&session);
        assert!(session.control_release(Some(lease + 1)).is_err());
        unchanged(&session);
        assert!(session.command_deny(lease + 1).is_err());
        unchanged(&session);
        // Successful operations still invalidate the revision a client polls with.
        session.command_deny(lease).unwrap();
        let denied: Value = serde_json::from_str(&session.snapshot(since, true).unwrap()).unwrap();
        assert_eq!(denied["changed"], true, "{denied}");
        session.control_release(Some(lease)).unwrap();
        let released: Value = serde_json::from_str(&session.snapshot(since, true).unwrap()).unwrap();
        assert_eq!(released["changed"], true, "{released}");
    }

    #[test]
    fn stale_authorize_leaves_the_snapshot_revision_unchanged() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let first: Value = serde_json::from_str(&session.snapshot(None, true).unwrap()).unwrap();
        let since = first["revision"].as_u64();
        // A stale lease fails before any audit append, so the snapshot must stay unchanged.
        assert!(session.command_authorize(lease + 1, "echo hi".into(), None).is_err());
        let stale: Value = serde_json::from_str(&session.snapshot(since, true).unwrap()).unwrap();
        assert_eq!(stale["changed"], false, "{stale}");
        // A failure that does append audit must still reach the host through a new revision.
        assert!(session.command_authorize(lease, "\u{1}".into(), None).is_err());
        let rejected: Value = serde_json::from_str(&session.snapshot(since, true).unwrap()).unwrap();
        assert_eq!(rejected["changed"], true, "{rejected}");
    }

    #[test]
    fn stale_execute_leaves_the_snapshot_revision_unchanged() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let first: Value = serde_json::from_str(&session.snapshot(None, true).unwrap()).unwrap();
        let since = first["revision"].as_u64();
        // A stale lease fails before consume, so the snapshot must stay unchanged.
        assert!(session.command_execute(lease + 1, 1, "echo hi".into()).is_err());
        let stale: Value = serde_json::from_str(&session.snapshot(since, true).unwrap()).unwrap();
        assert_eq!(stale["changed"], false, "{stale}");
        // A rejected dispatch would append dispatch_failed; a stale lease never reaches it.
        let audit = session.control_audit(0).unwrap();
        let events: Vec<&str> = audit["events"].as_array().unwrap().iter().filter_map(|e| e["event"].as_str()).collect();
        assert!(!events.contains(&"dispatch_failed"), "{audit}");
        // A grant mismatch does append audit, so it must still invalidate the snapshot.
        let authorization = session.command_authorize(lease, "echo hi".into(), None).unwrap()["authorization"].as_u64().unwrap();
        let baseline: Value = serde_json::from_str(&session.snapshot(None, true).unwrap()).unwrap();
        let baseline = baseline["revision"].as_u64();
        assert!(session.command_execute(lease, authorization, "echo nope".into()).is_err());
        let mismatch: Value = serde_json::from_str(&session.snapshot(baseline, true).unwrap()).unwrap();
        assert_eq!(mismatch["changed"], true, "{mismatch}");
    }
}

#[cfg(test)]
mod reply_tests {
    use super::*;

    #[test]
    fn reply_flood_is_dropped_at_the_backlog_cap_instead_of_ending_the_session() {
        let mut output = VecDeque::new();
        let mut pending = 0;
        let reply = b"\x1b[1;1R".to_vec();
        let mut dropped = 0;
        for _ in 0..20_000 {
            if !queue_replies(&mut output, &mut pending, reply.clone()) {
                dropped += 1;
            }
        }
        assert!(pending <= MAX_REPLY_BACKLOG);
        assert_eq!(pending, output.iter().map(|(bytes, _, _)| bytes.len()).sum::<usize>());
        assert!(dropped > 0);
        assert!(queue_replies(&mut output, &mut pending, Vec::new()), "empty replies are never a drop");
    }

    #[test]
    fn dropped_reply_backlog_advances_the_revision_so_a_since_poll_reports_it() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let mut output = VecDeque::new();
        // Saturated, so the next answer must be dropped instead of queued.
        let mut response_pending = MAX_REPLY_BACKLOG;
        let mut state = session.model.lock().unwrap();
        let replies = state.feed(b"\x1b[6n");
        assert!(!replies.is_empty(), "the query must produce a reply to drop");
        // The revision the host would hold after the feed that produced the reply.
        let since = state.revision;
        queue_parser_replies(&mut state, &mut output, &mut response_pending, replies);
        let recorded = state.error.clone();
        let revision = state.revision;
        drop(state);
        assert_eq!(recorded.as_deref(), Some(REPLY_BACKLOG_ERROR));
        assert_ne!(revision, since, "recording a dropped reply must advance the revision");
        // A poll at the held revision must both report a change and carry the error.
        let polled: Value = serde_json::from_str(&session.snapshot(Some(since), true).unwrap()).unwrap();
        assert_eq!(polled["changed"], true, "the drop must not be hidden: {polled}");
        assert_eq!(polled["error"], REPLY_BACKLOG_ERROR, "{polled}");
    }

    #[test]
    fn clean_finalization_keeps_the_error_the_host_was_already_shown() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.model.lock().unwrap().error = Some(REPLY_BACKLOG_ERROR.into());
        // A clean shutdown has no IO failure, so it must not turn a reported error into success.
        finalize(&session.model, Some(0), None).unwrap();
        let model = session.model.lock().unwrap();
        assert_eq!(model.error.as_deref(), Some(REPLY_BACKLOG_ERROR));
        assert!(model.exited);
        assert_eq!(model.exit_code, Some(0));
        drop(model);
        // A real IO failure still becomes the error the host reads.
        finalize(&session.model, Some(1), Some("PTY read failed")).unwrap();
        assert_eq!(session.model.lock().unwrap().error.as_deref(), Some("PTY read failed"));
    }

    #[test]
    fn post_exit_drain_queues_the_replies_the_program_asked_for() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let mut output = VecDeque::new();
        let mut response_pending = 0;
        // The post-exit drain must share the live feed's reply queueing: answers parsed
        // after the shell exits used to be dropped on the floor.
        feed_and_queue(&session.model, &mut output, &mut response_pending, b"\x1b[6n").unwrap();
        let queued: Vec<u8> = output.iter().flat_map(|(bytes, _, _)| bytes.iter().copied()).collect();
        assert!(!queued.is_empty(), "post-exit replies must reach the PTY: {queued:?}");
        assert_eq!(queued, b"\x1b[1;1R");
        assert_eq!(response_pending, queued.len(), "queued bytes must count against the backlog");
    }

    /// A connected descriptor pair where `0` is the nonblocking "master" the worker owns and
    /// `1` is the program's end. Lets the drain and flush be driven without a real PTY.
    /// Both ends are nonblocking so a missing reply fails the assertion instead of hanging.
    fn socket_pair() -> (i32, i32) {
        let mut fds = [0i32; 2];
        // SAFETY: fds is a valid two-element array for socketpair(2).
        assert_eq!(unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, fds.as_mut_ptr()) }, 0);
        for fd in fds {
            // SAFETY: each fd is a descriptor this test owns, so changing its flags is sound.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            assert_eq!(unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) }, 0);
        }
        (fds[0], fds[1])
    }

    #[test]
    fn post_exit_drain_writes_the_reply_back_to_the_terminal() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (master, program) = socket_pair();
        // The program's last act is to ask for a cursor position report.
        let query = b"\x1b[6n";
        // SAFETY: writing a valid slice into a descriptor this test owns.
        assert_eq!(unsafe { libc::write(program, query.as_ptr().cast(), query.len()) }, 4);
        let pending = AtomicUsize::new(0);
        let mut output = VecDeque::new();
        let mut response_pending = 0;
        let stop = AtomicBool::new(false);
        let failure = drain_after_exit(master, &session.model, &mut output, &mut response_pending, &pending, &stop);
        assert!(failure.is_none(), "{failure:?}");
        // The answer must be written back, not merely left queued for a reader that never runs.
        let mut received = [0u8; 16];
        // SAFETY: reading into a valid buffer from a descriptor this test owns.
        let count = unsafe { libc::read(program, received.as_mut_ptr().cast(), received.len()) };
        assert!(count > 0, "the drain wrote no reply back to the terminal");
        assert_eq!(&received[..count.max(0) as usize], b"\x1b[1;1R");
        assert!(output.is_empty(), "the drain must deliver what it queued: {output:?}");
        assert_eq!(response_pending, 0);
        // SAFETY: closing descriptors this test created.
        unsafe { libc::close(master); libc::close(program) };
    }

    #[test]
    fn final_flush_keeps_reply_order_and_never_sends_stale_input() {
        let (master, program) = socket_pair();
        let pending = AtomicUsize::new(12);
        let mut response_pending = 15;
        let mut output: VecDeque<(Vec<u8>, usize, bool)> = VecDeque::new();
        // Queued in worker order: input the exited child can never read, then two replies.
        output.push_back((b"stale input\r".to_vec(), 0, true));
        output.push_back((b"\x1b[1;1R".to_vec(), 0, false));
        output.push_back((b"\x1b[?62;22c".to_vec(), 0, false));
        let delivered = flush_replies(master, &mut output, &mut response_pending, &pending);
        assert!(delivered, "queued replies must actually be written");
        assert!(output.is_empty(), "the flush must drain the queue: {output:?}");
        assert_eq!(response_pending, 0, "delivered replies leave the backlog");
        assert_eq!(pending.load(Ordering::SeqCst), 0, "stale input releases its reservation");
        let mut received = [0u8; 32];
        // SAFETY: reading into a valid buffer from a descriptor this test owns.
        let count = unsafe { libc::read(program, received.as_mut_ptr().cast(), received.len()) };
        assert_eq!(&received[..count.max(0) as usize], b"\x1b[1;1R\x1b[?62;22c");
        // SAFETY: closing descriptors this test created.
        unsafe { libc::close(master); libc::close(program) };
    }

    #[test]
    fn final_flush_delivers_every_queued_reply_in_order() {
        let (master, program) = socket_pair();
        let pending = AtomicUsize::new(0);
        // One entry per reply, each already writable: a fixed per-call write budget would
        // deliver only the first batch and leave the rest of a bounded backlog unanswered.
        let replies: Vec<u8> = (0..20u8).map(|index| b'a' + index).collect();
        let mut response_pending = replies.len();
        let mut output: VecDeque<(Vec<u8>, usize, bool)> =
            replies.iter().map(|byte| (vec![*byte], 0, false)).collect();
        let delivered = flush_replies(master, &mut output, &mut response_pending, &pending);
        assert!(delivered, "queued replies must actually be written");
        assert!(output.is_empty(), "the flush must drain the whole queue: {output:?}");
        assert_eq!(response_pending, 0, "every delivered reply leaves the backlog");
        let mut received = [0u8; 32];
        // SAFETY: reading into a valid buffer from a descriptor this test owns.
        let count = unsafe { libc::read(program, received.as_mut_ptr().cast(), received.len()) };
        assert_eq!(count, replies.len() as isize, "replies were truncated: {count} of {}", replies.len());
        assert_eq!(&received[..replies.len()], &replies[..], "replies must keep their queue order");
        // SAFETY: closing descriptors this test created.
        unsafe { libc::close(master); libc::close(program) };
    }

    #[test]
    fn final_flush_resets_the_blocked_budget_after_every_written_reply() {
        // A pipe behaves like the PTY output queue here: writing into a full queue blocks until
        // the program end reads, so progress and blocking alternate.
        let mut fds = [0i32; 2];
        // SAFETY: fds is a valid two-element array for pipe(2).
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let (program, master) = (fds[0], fds[1]);
        // SAFETY: master is a descriptor this test owns, so changing its flags is sound.
        let flags = unsafe { libc::fcntl(master, libc::F_GETFL) };
        assert_eq!(unsafe { libc::fcntl(master, libc::F_SETFL, flags | libc::O_NONBLOCK) }, 0);
        let flags = unsafe { libc::fcntl(program, libc::F_GETFL) };
        assert_eq!(unsafe { libc::fcntl(program, libc::F_SETFL, flags | libc::O_NONBLOCK) }, 0);
        // Fill the queue: every reply write then starts out blocked.
        let filler = vec![b'F'; 64 * 1024];
        let mut filled = 0;
        loop {
            // SAFETY: writing a valid slice into a descriptor this test owns.
            let written = unsafe { libc::write(master, filler.as_ptr().cast(), filler.len()) };
            if written > 0 {
                filled += written as usize;
                continue;
            }
            let error = std::io::Error::last_os_error();
            assert!(
                matches!(error.kind(), std::io::ErrorKind::WouldBlock),
                "unexpected fill failure: {error}"
            );
            break;
        }
        // The program end consumes the queue the way a live reader would, one reply at a time.
        let stop = Arc::new(AtomicBool::new(false));
        let pump_stop = Arc::clone(&stop);
        let pump = std::thread::spawn(move || {
            let mut seen = Vec::new();
            let mut chunk = [0u8; 1024];
            // Let the flush run into the full queue before the first byte is consumed.
            std::thread::sleep(std::time::Duration::from_millis(1));
            loop {
                // SAFETY: reading into a valid buffer from a descriptor this test owns.
                let count = unsafe { libc::read(program, chunk.as_mut_ptr().cast(), chunk.len()) };
                if count > 0 {
                    seen.extend_from_slice(&chunk[..count as usize]);
                }
                if pump_stop.load(Ordering::SeqCst) {
                    // Drain whatever the last write left so the assertion sees every byte.
                    if count <= 0 {
                        return seen;
                    }
                    continue;
                }
                std::thread::sleep(std::time::Duration::from_micros(400));
            }
        });
        let pending = AtomicUsize::new(0);
        let expected: Vec<u8> = (0..6u8).flat_map(|index| std::iter::repeat_n(b'A' + index, 1024)).collect();
        let mut response_pending = expected.len();
        let mut output: VecDeque<(Vec<u8>, usize, bool)> = expected
            .chunks(1024)
            .map(|chunk| (chunk.to_vec(), 0, false))
            .collect();
        let delivered = flush_replies(master, &mut output, &mut response_pending, &pending);
        stop.store(true, Ordering::SeqCst);
        let seen = pump.join().unwrap();
        assert!(delivered, "a live reader must not end the flush on the first blocked attempt");
        assert!(output.is_empty(), "the flush must keep going after progress: {output:?}");
        assert_eq!(response_pending, 0, "every delivered reply leaves the backlog");
        assert!(
            seen.len() >= filled + expected.len(),
            "the reader saw {} of {} bytes",
            seen.len(),
            filled + expected.len()
        );
        assert_eq!(&seen[filled..], &expected[..], "progress must resume after each block");
        // SAFETY: closing descriptors this test created.
        unsafe { libc::close(master); libc::close(program) };
    }

    #[test]
    fn post_exit_drain_answers_every_burst_separated_by_an_idle_window() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (master, program) = socket_pair();
        // Three bursts, each written after the drain has already seen an empty read. A shared
        // idle budget spends itself on the earlier gaps and the last burst is never answered.
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(0);
        let writer = std::thread::spawn(move || {
            for (index, query) in [b"\x1b[c".as_slice(), b"\x1b[6n", b"\x1b[c"].into_iter().enumerate() {
                std::thread::sleep(std::time::Duration::from_millis(5));
                // SAFETY: writing a valid slice into a descriptor this test owns.
                assert_eq!(unsafe { libc::write(program, query.as_ptr().cast(), query.len()) }, query.len() as isize);
                if index == 0 { started_tx.send(()).unwrap(); }
            }
        });
        // Start the bounded drain only after the writer has actually been scheduled.
        started_rx.recv().unwrap();
        let pending = AtomicUsize::new(0);
        let mut output = VecDeque::new();
        let mut response_pending = 0;
        let stop = AtomicBool::new(false);
        let failure = drain_after_exit(master, &session.model, &mut output, &mut response_pending, &pending, &stop);
        assert!(failure.is_none(), "{failure:?}");
        writer.join().unwrap();
        let mut received = [0u8; 64];
        // SAFETY: reading into a valid buffer from a descriptor this test owns.
        let count = unsafe { libc::read(program, received.as_mut_ptr().cast(), received.len()) };
        let answers = b"\x1b[?62;22c\x1b[1;1R\x1b[?62;22c";
        assert!(count > 0, "the drain wrote no reply back to the terminal");
        assert_eq!(&received[..count as usize], answers, "every separated burst must be answered in order");
        assert_eq!(response_pending, 0, "every burst must leave the backlog");
        assert!(output.is_empty(), "the drain must deliver what it queued: {output:?}");
        // SAFETY: closing descriptors this test created.
        unsafe { libc::close(master); libc::close(program) };
    }

    #[test]
    fn final_flush_with_a_vanished_program_is_not_an_error() {
        let (master, program) = socket_pair();
        // SAFETY: closing the peer this test owns stands in for the program exiting.
        unsafe { libc::close(program) };
        let pending = AtomicUsize::new(0);
        let mut response_pending = 6;
        let mut output = VecDeque::from([(b"\x1b[1;1R".to_vec(), 0, false)]);
        // Best effort: a reply nobody can read must not turn a clean exit into a session error,
        // and must not panic on the broken pipe.
        let delivered = flush_replies(master, &mut output, &mut response_pending, &pending);
        assert!(!delivered, "nothing can be delivered to a vanished program");
        // SAFETY: closing the remaining descriptor this test owns.
        unsafe { libc::close(master) };
    }
}
