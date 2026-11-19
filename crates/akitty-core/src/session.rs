use crate::chrome;
use crate::child::{ChildGuard, ChildSlot};
use crate::model::{Model, Size};
use akitty_vt::screen::Position;
use portable_pty::{CommandBuilder, PtySize};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const MAX_PENDING: usize = 1_048_576;
/// Host-visible failure text after an engine panic: the pane is done, but restarting it is safe.
pub(crate) const ENGINE_FAILED: &str = "Terminal engine error. Use Shell → Restart Terminal.";
enum Command {
    Input(Vec<u8>),
    Resize(Size),
    /// Test-only: make the worker unwind so the panic path is exercised end to end.
    #[cfg(test)]
    Panic,
}
pub struct Session {
    model: Arc<Mutex<Model>>,
    commands: Option<mpsc::SyncSender<Command>>,
    stop: Arc<AtomicBool>,
    pending: Arc<AtomicUsize>,
    /// Serializes snapshot build/commit pairs. Held across serialization, which runs outside the model lock:
    /// without it two hosts could commit events a snapshot never carried.
    snapshot_lock: Mutex<()>,
    /// Self-pipe the worker polls next to the PTY: a queued command or a stop must not wait
    /// for the idle timeout. Absent on headless sessions, which have no worker.
    wake: Option<Arc<Wake>>,
    /// Host-visible change pipe: one byte per worker pass that advanced the model, so the UI can
    /// poll on demand instead of a fixed timer. Core-owned; `notify_fd` lends the read end.
    notify: Option<Arc<Wake>>,
    worker: Mutex<Option<JoinHandle<Result<(), String>>>>,
    /// Device number of the PTY's terminal side. A process whose controlling terminal has this
    /// number was started inside this pane; the host uses it to bind local requests to their pane.
    tty_device: Option<u64>,
}
/// Nonblocking, close-on-exec pipe used for readiness only, never for payload: a full pipe is
/// already a pending wake, so signals may drop their byte. The worker owns a self-pipe; a real
/// session also exposes a host-notification pipe of the same shape (`notify_fd`).
struct Wake {
    read: i32,
    write: i32,
}
impl Wake {
    fn new() -> Result<Self, String> {
        let mut fds = [0i32; 2];
        // SAFETY: fds is a valid two-element array for pipe(2).
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(format!("terminal wake pipe unavailable: {}", std::io::Error::last_os_error()));
        }
        // Both ends are owned by this Wake, so a failure here closes them through Drop.
        let wake = Self { read: fds[0], write: fds[1] };
        for fd in [wake.read, wake.write] {
            // SAFETY: fd is one of the descriptors this Wake just created.
            let status = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if status < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, status | libc::O_NONBLOCK) } < 0 {
                return Err(format!("terminal wake pipe unavailable: {}", std::io::Error::last_os_error()));
            }
            // Close on exec, so the shell and its descendants never inherit a wake end.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
                return Err(format!("terminal wake pipe unavailable: {}", std::io::Error::last_os_error()));
            }
        }
        Ok(wake)
    }
    /// Ask the worker to leave `poll` now. EAGAIN means a wake is already pending.
    fn signal(&self) {
        let byte = 1u8;
        // SAFETY: writes one byte from a live local into the owned wake descriptor.
        unsafe { libc::write(self.write, (&byte as *const u8).cast(), 1) };
    }
    /// Read end the host may poll. The core keeps ownership (both ends close in `Drop`), so the
    /// host must stop reading before the session closes rather than closing this descriptor.
    fn read_fd(&self) -> i32 {
        self.read
    }
    /// Consume every pending wake byte; the poll flags already delivered the wake itself.
    fn drain(&self) {
        let mut buffer = [0u8; 64];
        loop {
            // SAFETY: buffer is writable for its length; read reports invalid descriptors as EBADF.
            let count = unsafe { libc::read(self.read, buffer.as_mut_ptr().cast(), buffer.len()) };
            if count > 0 {
                continue;
            }
            if count == 0 || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                return;
            }
        }
    }
}
impl Drop for Wake {
    fn drop(&mut self) {
        // SAFETY: both descriptors are owned by this Wake and closed exactly once here.
        unsafe { libc::close(self.read); libc::close(self.write) };
    }
}
/// The two readiness pipes the worker owns: its wake self-pipe and the host-notify pipe. Grouped
/// so the worker entry point stays at clippy's argument bound without hiding either one.
struct Wakes {
    wake: Arc<Wake>,
    notify: Arc<Wake>,
}
/// Worker-side access to the terminal state. A host panic may poison the mutex, but the exit path
/// still has to publish `exited`, so the worker reuses whatever state the panic left behind.
fn lock_model(model: &Mutex<Model>) -> std::sync::MutexGuard<'_, Model> {
    model.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}
/// The bundled bash/zsh integration a session starts with.
pub struct ShellIntegration {
    pub directory: String,
    /// False starts the shell with AKITTY_FOLDER_HISTORY=0.
    pub folder_history: bool,
}
#[derive(Default)]
pub struct SessionConfig {
    pub shell: Option<String>,
    pub cwd: Option<String>,
    pub integration: Option<ShellIntegration>,
    pub restored_text: Option<String>,
}
impl Session {
    #[cfg(test)]
    pub fn new(
        cols: usize,
        rows: usize,
        shell: Option<String>,
        cwd: Option<String>,
        headless: bool,
        scrollback: usize,
        integration: Option<ShellIntegration>,
    ) -> Result<Self, String> {
        Self::new_configured(cols, rows, headless, scrollback, SessionConfig { shell, cwd, integration, restored_text: None })
    }
    pub fn new_configured(cols: usize, rows: usize, headless: bool, scrollback: usize, config: SessionConfig) -> Result<Self, String> {
        let SessionConfig { shell, cwd, integration, restored_text } = config;
        if scrollback > 20000 { return Err("scrollback exceeds 20000 lines".into()); }
        let size = Size::validate(cols, rows)?;
        let mut initial = Model::new(size, scrollback);
        if let Some(text) = restored_text { initial.restore_text(&text)?; }
        // Populate only the model, before the PTY starts. Saved text is never shell input.
        let model = Arc::new(Mutex::new(initial));
        let stop = Arc::new(AtomicBool::new(false));
        let pending = Arc::new(AtomicUsize::new(0));
        if headless {
            return Ok(Self {
                model,
                commands: None,
                stop,
                pending,
                snapshot_lock: Mutex::new(()),
                wake: None,
                notify: None,
                worker: Mutex::new(None),
                tty_device: None,
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
        let tty_device = pty.master.tty_name().and_then(|path| {
            use std::os::unix::fs::MetadataExt;
            std::fs::metadata(path).ok().map(|meta| meta.rdev())
        });
        // SAFETY: fd is owned by pty.master, which outlives the worker.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let mut cmd = CommandBuilder::new(&shell);
        if let Some(ShellIntegration { directory, folder_history }) = integration {
            if directory.len() > 4096 || !std::path::Path::new(&directory).is_absolute() {
                return Err("shell integration directory must be an absolute path of at most 4096 bytes".into());
            }
            let root = std::path::Path::new(&directory);
            let name = std::path::Path::new(&shell).file_name().and_then(|n|n.to_str()).unwrap_or("");
            let resource = match name { "bash" => "bashrc", "zsh" => ".zshenv", _ => return Err("shell integration supports bash and zsh only".into()) };
            if !root.join(resource).is_file() { return Err("shell integration resources missing".into()); }
            cmd.env("AKITTY_INTEGRATION_DIR", &directory);
            if !folder_history { cmd.env("AKITTY_FOLDER_HISTORY", "0"); }
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
        let wake = Arc::new(Wake::new()?);
        // Separate from the worker wake: a host reading slowly must never delay the PTY loop.
        let notify = Arc::new(Wake::new()?);
        let (tx, rx) = mpsc::sync_channel(4096);
        let model_worker = model.clone();
        let stop_worker = stop.clone();
        let pending_worker = pending.clone();
        let wake_worker = wake.clone();
        let notify_worker = notify.clone();
        let panic_model = model.clone();
        let panic_notify = notify.clone();
        let clock_wake = wake.clone();
        let clock_stop = stop.clone();
        let worker = thread::Builder::new()
            .name("akitty-pty".into())
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run(
                        pty.master,
                        child,
                        rx,
                        model_worker,
                        stop_worker,
                        pending_worker,
                        Wakes { wake: wake_worker, notify: notify_worker },
                    )
                }));
                let result = outcome.unwrap_or_else(|_| {
                    // The parser or another engine step panicked with the state held. Publish a
                    // restartable failure instead of letting the dead thread strand the pane.
                    lock_model(&panic_model).error = Some(ENGINE_FAILED.into());
                    finalize(&panic_model, None, None, None);
                    // Finalize bumped the revision outside the loop, so tell the host explicitly.
                    panic_notify.signal();
                    Err("PTY worker panicked".into())
                });
                // Exit, failure or panic: the PTY and command channel are gone, but a timed status
                // on the finished pane still needs a clock until the session closes.
                keep_chrome_time(&panic_model, &clock_wake, &panic_notify, &clock_stop, None);
                result
            })
            .map_err(|e| e.to_string())?;
        Ok(Self {
            model,
            commands: Some(tx),
            stop,
            pending,
            snapshot_lock: Mutex::new(()),
            wake: Some(wake),
            notify: Some(notify),
            worker: Mutex::new(Some(worker)),
            tty_device,
        })
    }
    /// Host-side model access. A poisoned lock means a host panic left the state behind, so fail
    /// closed into a restartable session instead of reporting "unavailable" on every later call.
    fn state(&self) -> Result<std::sync::MutexGuard<'_, Model>, String> {
        match self.model.lock() {
            Ok(guard) => Ok(guard),
            Err(poisoned) => {
                let mut state = poisoned.into_inner();
                // Keep an error the panic path already published; only the first recovery names it.
                if state.error.is_none() { state.error = Some(ENGINE_FAILED.into()); }
                let exited = state.exited;
                drop(state);
                if exited {
                    // The worker already reached (or is about to reach) its own finalize, which will not run again:
                    // clear the poison here so the exit and its error stay observable instead of failing forever.
                    self.model.clear_poison();
                } else if self.commands.is_some() {
                    // The worker owns finalize: stop it so it publishes `exited` and clears the poison.
                    self.stop.store(true, Ordering::SeqCst);
                    self.wake();
                } else {
                    // No worker to finalize a headless session, so publish the exit here.
                    finalize(&self.model, None, None, None);
                }
                Err(ENGINE_FAILED.into())
            }
        }
    }
    /// Snapshot JSON, already serialized. The model lock covers the build and the commit only: serialization
    /// (1–19 ms on a dense screen) runs after it is released, so the PTY worker keeps feeding.
    #[cfg(test)]
    pub fn snapshot(&self, since: Option<u64>, compact: bool, allow_shift: bool) -> Result<String, String> {
        self.snapshot_with(since, compact, allow_shift, false).map(|(json, _)| json)
    }
    /// Snapshot plus the negotiated binary cell block. When `binary_cells` is honored the JSON head
    /// carries `cells: []` and `cells_binary` metadata, and the block follows a NUL on the wire.
    pub(crate) fn snapshot_with(
        &self,
        since: Option<u64>,
        compact: bool,
        allow_shift: bool,
        binary_cells: bool,
    ) -> Result<(String, Option<Vec<u8>>), String> {
        self.snapshot_inner(since, compact, allow_shift, binary_cells, crate::model::MAX_SNAPSHOT_BYTES)
    }
    /// `snapshot` with the size bound passed in, so a test can drive the oversize branch without an 8 MiB screen.
    #[cfg(test)]
    fn snapshot_within(&self, since: Option<u64>, compact: bool, allow_shift: bool, max_bytes: usize) -> Result<String, String> {
        self.snapshot_inner(since, compact, allow_shift, false, max_bytes).map(|(json, _)| json)
    }
    /// The binary-capable form of the same injected bound, for the size-accounting test.
    #[cfg(test)]
    fn snapshot_with_bound(
        &self,
        since: Option<u64>,
        compact: bool,
        allow_shift: bool,
        binary_cells: bool,
        max_bytes: usize,
    ) -> Result<(String, Option<Vec<u8>>), String> {
        self.snapshot_inner(since, compact, allow_shift, binary_cells, max_bytes)
    }
    fn snapshot_inner(
        &self,
        since: Option<u64>,
        compact: bool,
        allow_shift: bool,
        binary_cells: bool,
        max_bytes: usize,
    ) -> Result<(String, Option<Vec<u8>>), String> {
        // Two concurrent snapshots must not interleave build and commit, or one would consume events the
        // other never delivered. This lock, not the model lock, spans the serialization.
        // A host panic during a previous serialization poisons this lock, but it guards no data:
        // recover it so later snapshots are not blocked by a stale serializer failure.
        let _serialize = self.snapshot_lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let built = {
            let mut model = self.state()?;
            // Real PTY sessions expire in the worker, which owns delivery of replies.
            if self.commands.is_none() { model.expire_sync(); }
            model.build_snapshot(since, compact, allow_shift)?
        };
        let Some((mut value, commit)) = built else {
            return Ok((crate::model::UNCHANGED_SNAPSHOT.into(), None));
        };
        // The block replaces the JSON cells entirely, so the two never double-count.
        let binary = if binary_cells { value.take_binary_cells() } else { None };
        let json = serde_json::to_string(&value).expect("snapshot fields serialize");
        // The response limit covers the JSON head, its NUL separator and the block.
        let total = json.len() + binary.as_ref().map_or(0, |block| block.len() + 1);
        let mut model = self.state()?;
        if total > max_bytes {
            // Nothing the client would never receive may be committed; `sent` is dropped so the
            // next poll sends a full snapshot rather than a diff against it.
            model.forget_sent();
            return Err("snapshot exceeds 8 MiB".into());
        }
        model.commit_snapshot(commit);
        // A status that expired while this reply serialized is already stale on arrival, and the
        // worker may have checked before the commit. Wake the host once so its next poll clears it;
        // that poll commits the cleared state, so this cannot repeat.
        let stale = model.chrome_stale(chrome::now_ms());
        drop(model);
        if stale { self.notify_host(); }
        Ok((json, binary))
    }
    pub fn command_history(&self, after: u64) -> Result<Value, String> {
        Ok(self.state()?.shell.history(after))
    }
    pub fn recent_text(&self) -> Result<Value, String> {
        Ok(json!({"text": self.state()?.recent_text(), "untrusted": true}))
    }
    /// Shell and control summaries without a snapshot's side effects: a snapshot consumes
    /// pending bell and clipboard events, so hosts must not take one just to read the cwd.
    pub fn shell_state(&self) -> Result<Value, String> {
        let mut model = self.state()?;
        // An exited pane reports only final program records, as its next snapshot would.
        if model.exited { model.program_status.finish_work(); }
        // Status readers (Siri, the Overview) get the same title, exit and program reports a
        // snapshot carries, without taking the bell or clipboard events the pane's poller owns.
        Ok(serde_json::json!({
            "shell": model.shell.summary(), "control": model.control.summary(), "title": model.title,
            "exited": model.exited, "program_status": model.program_status.to_json(),
            "tty_device": self.tty_device,
        }))
    }
    pub fn command_output(&self, id: u64) -> Result<Value, String> {
        self.state()?.shell.command_output(id)
    }
    pub fn feed(&self, bytes: &[u8]) -> Result<(), String> {
        if self.commands.is_some() {
            return Err("feed is only available on headless sessions".into());
        }
        let mut model = self.state()?;
        for chunk in bytes.chunks(8192) {
            model.feed(chunk);
        }
        Ok(())
    }
    /// Read end of the host-notification pipe. The core owns both ends and closes them with the
    /// session, so the host must cancel its reader before `close`/drop instead of closing the fd.
    /// Headless sessions have no worker, so they return an error and the host polls explicitly.
    /// Wakes the host after a host-side change it may not poll for itself (an agent lease, a denial, chrome).
    /// A spurious wake costs one unchanged poll. Never call it for reads, or a snapshot would wake its own poller.
    pub(crate) fn notify_host(&self) {
        if let Some(notify) = &self.notify { notify.signal(); }
    }
    pub fn notify_fd(&self) -> Result<Value, String> {
        let notify = self.notify.as_ref().ok_or("headless session has no notification pipe")?;
        Ok(json!({"fd": notify.read_fd()}))
    }
    pub fn input(&self, text: String, paste: bool) -> Result<(), String> {
        if text.len() > 65536 {
            return Err("input exceeds 64 KiB".into());
        }
        let model = self.state()?;
        if model.exited {
            return Err("shell has exited".into());
        }
        let bytes = if paste && model.term.modes.bracketed_paste {
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
        let mut model = self.state()?;
        if model.exited || self.stop.load(Ordering::SeqCst) { return Err("shell has exited".into()); }
        let previous_dirty = model.control.dirty;
        model.control.human_input()?;
        // Zero bytes never reach the PTY, so the prompt was not edited: keep it authorizable
        // instead of leaving the dirty flag set by human_input behind.
        if bytes.is_empty() { model.control.dirty = previous_dirty; return self.enqueue_input(bytes); }
        if let Err(error) = self.enqueue_input(bytes) { model.control.dirty = previous_dirty; return Err(error); }
        model.term.screen_mut().offset = 0; model.revision += 1;
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
        self.wake();
        Ok(())
    }
    /// Leave the worker's poll early; a full pipe already holds the wake.
    fn wake(&self) {
        if let Some(wake) = &self.wake { wake.signal(); }
    }
    pub fn control_acquire(&self, actor: String) -> Result<Value, String> {
        let mut model = self.state()?;
        if model.exited { return Err("shell has exited".into()); }
        let result = model.control.acquire(actor); if result.is_ok() { model.revision += 1; } result
    }
    pub fn control_release(&self, lease: Option<u64>) -> Result<Value, String> {
        let mut model = self.state()?;
        let result = model.control.release(lease); if result.is_ok() { model.revision += 1; } result
    }
    pub fn command_authorize(&self, lease: u64, command: String, expected_cwd: Option<String>) -> Result<Value, String> {
        let mut model = self.state()?;
        if model.exited || !model.shell.ready || model.control.dirty { return Err("command requires an unedited integrated shell prompt".into()); }
        let cwd = model.shell.cwd.clone();
        if cwd != expected_cwd { return Err("working directory changed since approval request".into()); }
        let seq = model.control.audit_seq();
        let result = model.control.authorize(lease,command,cwd);
        if result.is_ok() || model.control.audit_seq() != seq { model.revision += 1; }
        result
    }
    pub fn command_deny(&self, lease: u64) -> Result<Value, String> {
        let mut model = self.state()?;
        let result = model.control.deny(lease); if result.is_ok() { model.revision += 1; } result
    }
    pub fn command_execute(&self, lease: u64, authorization: u64, command: String) -> Result<Value, String> {
        let mut model = self.state()?;
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
        // Ctrl-U first: keys typed while the previous command ran reach the new prompt
        // as typeahead after 133;A cleared `dirty`, and must not prefix this command.
        // bash, zsh (emacs and vi insert) and the tty's VKILL all erase to line start.
        if let Err(error) = self.enqueue_input(format!("\x15{command}\r").into_bytes()) {
            model.control.dispatch_failed(); return Err(error);
        }
        model.shell.ready = false; model.control.dirty = true; model.revision += 1;
        Ok(json!({"accepted":true,"after_command_id":model.shell.summary()["last_command_id"],"completion_untrusted":true}))
    }
    pub fn control_audit(&self, after: u64) -> Result<Value, String> {
        Ok(self.state()?.control.audit(after))
    }
    pub fn resize(&self, cols: usize, rows: usize) -> Result<(), String> {
        let size = Size::validate(cols, rows)?;
        let mut model = self.state()?;
        if let Some(sender) = &self.commands {
            // Record the grid before the send so a concurrent pixel-size push repeats
            // this request instead of the worker's still-stale applied size.
            let previous = model.requested_size;
            model.requested_size = size;
            if let Err(error) = sender.try_send(Command::Resize(size)) {
                model.requested_size = previous;
                return Err(format!("resize rejected: {error}"));
            }
            self.wake();
        } else {
            model.resize_grid(size);
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
        let mut model = self.state()?;
        let previous = model.cell_px;
        // Repeat the latest queued grid, not the applied one, so a scale change cannot
        // re-send an older grid after the new resize the host already recorded.
        let size = model.requested_size;
        model.cell_px = (width, height);
        // Push a PTY resize so TIOCGWINSZ reports the new pixel size even
        // though the grid itself did not change. Headless sessions just store it.
        if let Some(sender) = &self.commands {
            if let Err(error) = sender.try_send(Command::Resize(size)) {
                // The PTY did not accept the resize, so keep the grid's geometry
                // consistent: restore the old pixel size and leave the revision alone.
                model.cell_px = previous;
                return Err(format!("resize rejected: {error}"));
            }
            self.wake();
        }
        // Placeholder geometry is derived from cell_px, so a successful change must
        // invalidate snapshots a client could otherwise serve from its cached revision.
        model.revision += 1;
        Ok(())
    }
    pub fn read_image(&self, image: u32, out: &mut [u8]) -> usize {
        // Hold the pixels by reference count under the lock, then copy outside it: a frame can be tens of MiB
        // and the worker must not wait for the copy. The held buffer is the frame that was on display.
        let pixels = {
            let Ok(model) = self.state() else { return 0 };
            let Some(found) = model.graphics.images.get(&image) else { return 0 };
            if found.rgba.len() > out.len() { return 0; }
            Arc::clone(&found.rgba)
        };
        out[..pixels.len()].copy_from_slice(&pixels);
        pixels.len()
    }
    pub fn scroll(&self, lines: i32) -> Result<(), String> {
        let mut model = self.state()?;
        model.term.screen_mut().scroll_display(lines.clamp(-5000, 5000));
        model.revision += 1;
        Ok(())
    }
    pub fn select(&self, sr: usize, sc: usize, er: usize, ec: usize) -> Result<Value, String> {
        let mut model = self.state()?;
        if sr >= model.size.rows
            || er >= model.size.rows
            || sc >= model.size.cols
            || ec >= model.size.cols
        {
            return Err("selection outside viewport".into());
        }
        model.term.screen_mut().select(Position { row: sr, col: sc }, Position { row: er, col: ec });
        model.revision += 1;
        Ok(json!({"text": model.term.screen().selection_text()}))
    }
    pub fn find(&self, text: &str, direction: Option<&str>, clear: bool) -> Result<Value, String> {
        let mut model = self.state()?;
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
        self.state()?.set_chrome(input)?;
        // The worker keeps the clock for a timed status, so it must see a new expiry now
        // rather than after its idle poll.
        self.wake();
        Ok(())
    }
    pub fn set_theme(&self, theme: &crate::model::Theme) -> Result<(), String> {
        self.state()?.set_theme(theme);
        Ok(())
    }
    pub fn set_program_chrome(&self, enabled: bool) -> Result<(), String> {
        self.state()?.set_program_chrome(enabled);
        Ok(())
    }
    pub fn close(&self) -> Result<(), String> {
        self.shutdown()
    }
    fn shutdown(&self) -> Result<(), String> {
        self.stop.store(true, Ordering::SeqCst);
        // Wake the worker out of its idle poll so close never waits for the timeout.
        self.wake();
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

/// One hand-off slot between the PTY reader and the parser: also the largest single read.
const SLOT_BYTES: usize = 64 * 1024;
/// Fixed slot ring. Ownership of a slot moves between the stages, so a read is never copied and
/// the ring is the whole backlog: a parser that falls behind stops the reader instead of growing.
const RING_SLOTS: usize = 4;
/// Keep the model lock bounded to 8 KiB of parsing, even when a whole slot is ready.
const PARSE_BATCH: usize = 8 * 1024;
/// Bytes one worker pass applies before it services input, resize and the host again. One ring
/// covers it exactly, so a command never waits behind more than one full ring and a slot is never
/// split across passes.
const MAX_PARSE_PER_PASS: usize = RING_SLOTS * SLOT_BYTES;

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
/// feed cannot reset the backlog between the expiry and the drop decision. Returns the next
/// deadline the worker must poll for, so a synchronized update or a timed chrome status
/// expires on time instead of at the idle timeout or the host's safety tick.
/// `chrome_signalled` names the delivered status the host was already woken for, if it is stale.
fn expire_and_queue(
    model: &Arc<Mutex<Model>>,
    output: &mut VecDeque<(Vec<u8>, usize, bool)>,
    response_pending: &mut usize,
    notify: &Wake,
    chrome_signalled: &mut Option<u64>,
) -> Option<Instant> {
    let mut state = lock_model(model);
    let before = state.revision;
    let replies = state.expire_sync();
    queue_parser_replies(&mut state, output, response_pending, replies);
    let (chrome_due, chrome_next) = chrome_tick(&state, chrome_signalled);
    let deadline = earliest(state.sync_deadline(), chrome_next);
    let changed = state.revision != before;
    drop(state);
    // A synchronized-update deadline can pass with no output, yet the host must refresh.
    if changed || chrome_due { notify.signal(); }
    deadline
}

/// Chrome timekeeping for one worker pass: whether to wake the host, and when to look again.
/// A timed status leaves the next snapshot without any output or revision change, so the host
/// is woken once while it still shows a status that has gone. This compares against what the
/// host last received rather than an expiry the worker saw earlier, so a status that was set
/// and expired between two passes is still announced. `signalled` names the delivered status the
/// host was woken for, so a second status delivered and expired before the worker's next pass
/// is announced too instead of being taken for the first.
fn chrome_tick(state: &Model, signalled: &mut Option<u64>) -> (bool, Option<Instant>) {
    let now_ms = chrome::now_ms();
    let stale = state.chrome_stale(now_ms).then(|| state.transient_report());
    let due = stale.is_some() && stale != *signalled;
    *signalled = stale;
    (due, chrome_deadline(state.chrome_expiry(now_ms), now_ms))
}

/// The worker deadline for a Unix-millisecond chrome expiry. A program chooses `expires`, so a
/// date too far ahead to represent simply never expires instead of overflowing.
fn chrome_deadline(expiry: Option<u64>, now_ms: u64) -> Option<Instant> {
    let delay = std::time::Duration::from_millis(expiry?.saturating_sub(now_ms));
    Instant::now().checked_add(delay)
}

/// After exit the worker is the session's only clock. Keep announcing a timed status the host
/// still shows until it expires, including one the host sets on the exited pane; close ends the
/// wait through the worker wake.
fn keep_chrome_time(model: &Arc<Mutex<Model>>, wake: &Wake, notify: &Wake, stop: &AtomicBool, mut signalled: Option<u64>) {
    while !stop.load(Ordering::SeqCst) {
        let (due, next) = chrome_tick(&lock_model(model), &mut signalled);
        if due { notify.signal(); }
        // Nothing else happens on an exited pane, so sleep until the expiry or a wake, not the idle bound.
        let timeout = next.map_or(-1, |deadline| {
            deadline.saturating_duration_since(Instant::now()).as_millis().saturating_add(1).min(libc::c_int::MAX as u128) as libc::c_int
        });
        let mut poll = libc::pollfd { fd: wake.read, events: libc::POLLIN, revents: 0 };
        // SAFETY: poll references one valid pollfd owned by this frame.
        if unsafe { libc::poll(&mut poll, 1, timeout) } > 0 { wake.drain(); }
    }
}

fn earliest(a: Option<Instant>, b: Option<Instant>) -> Option<Instant> {
    match (a, b) { (Some(a), Some(b)) => Some(a.min(b)), (a, b) => a.or(b) }
}

/// How one drain of ready bytes ended.
enum Fill {
    /// The read would block (or a stop/finish arrived): nothing more is readable now.
    Idle,
    /// The stream ended; the bytes before it were published.
    Ended,
    /// Every slot is waiting for the parser, so the reader must wait for one back.
    Full,
}

/// The two-stage hand-off. Stage one (the reader thread) owns every `read(2)` and never takes the
/// model lock; stage two (the worker thread) owns the model, replies, writes, resize and the child.
/// A slot's ownership moves from the free list to the ready queue to the parser and back, so a
/// read is never copied and the ring itself is the whole backlog: backpressure stops the reader
/// instead of growing memory, and a short tail is published with the reads that produced it.
struct Ring {
    shared: Mutex<RingShared>,
    /// Parser-idle pipe for a bridging reader: [`Ring::recycle`] writes it only while the reader
    /// is bridging and the parser has just run out of published bytes, so an interactive
    /// terminal never pays for it. `None` in tests that drive the ring without a reader.
    idle: Option<Wake>,
    /// The parser waits here for a published slot, and for the reader's end.
    ready: Condvar,
    /// The reader waits here for a slot the parser has finished with.
    space: Condvar,
}
struct RingShared {
    free: Vec<Box<[u8]>>,
    ready: VecDeque<(Box<[u8]>, usize)>,
    /// Slots the parser took but has not returned, so `idle` cannot claim they were applied.
    in_flight: usize,
    /// `None` while the reader keeps reading; otherwise why it stopped.
    end: Option<Result<(), String>>,
    /// The reader is waiting in a bridge poll with a partly filled slot while the parser is busy.
    /// Set and cleared under the ring lock, so the parser's idle signal cannot be missed.
    bridging: bool,
}
/// A condvar wait never blocks a stop check for longer than this.
const RING_WAIT_MS: u64 = 10;

impl Ring {
    #[cfg(test)]
    fn new() -> Self {
        Self::build(None)
    }
    /// A ring whose reader may bridge refill gaps (see [`fill_ring_coalescing`]).
    fn with_idle_wake() -> Result<Self, String> {
        Ok(Self::build(Some(Wake::new()?)))
    }
    fn build(idle: Option<Wake>) -> Self {
        let free = (0..RING_SLOTS).map(|_| vec![0u8; SLOT_BYTES].into_boxed_slice()).collect();
        Self {
            shared: Mutex::new(RingShared {
                free, ready: VecDeque::with_capacity(RING_SLOTS), in_flight: 0, end: None, bridging: false,
            }),
            idle,
            ready: Condvar::new(),
            space: Condvar::new(),
        }
    }
    /// Read end of the parser-idle pipe, when this ring has one.
    fn idle_fd(&self) -> Option<i32> {
        self.idle.as_ref().map(Wake::read_fd)
    }
    /// Enter a bridge wait if the parser still has published bytes to apply. Waiting is only free
    /// while it hides behind parse time: with an idle parser every held microsecond is output
    /// latency, and a program waiting on a reply to bytes in the held slot would never refill.
    fn begin_bridge(&self) -> bool {
        if self.idle.is_none() { return false; }
        let mut shared = self.lock();
        let busy = !shared.ready.is_empty() || shared.in_flight > 0;
        shared.bridging = busy;
        busy
    }
    /// Leave a bridge wait. Clearing under the lock ends the parser's idle writes, so the drain
    /// that follows cannot leave a stale byte to cut the next bridge short.
    fn end_bridge(&self) {
        self.lock().bridging = false;
        if let Some(idle) = &self.idle { idle.drain(); }
    }
    /// A poisoned ring still has to drain and report its end: no host data sits behind this lock.
    fn lock(&self) -> std::sync::MutexGuard<'_, RingShared> {
        self.shared.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
    /// Take a free slot, or `None` when the parser still holds every one of them.
    fn checkout(&self) -> Option<Box<[u8]>> {
        self.lock().free.pop()
    }
    /// Wait up to `within` for a free slot. Bounded so a drain can never outlive its window.
    fn checkout_within(&self, within: Duration) -> Option<Box<[u8]>> {
        let deadline = Instant::now() + within;
        let mut shared = self.lock();
        loop {
            if let Some(slot) = shared.free.pop() { return Some(slot); }
            let now = Instant::now();
            if now >= deadline { return None; }
            shared = self.space.wait_timeout(shared, deadline - now).unwrap_or_else(|poisoned| poisoned.into_inner()).0;
        }
    }
    fn publish(&self, slot: Box<[u8]>, len: usize) {
        self.lock().ready.push_back((slot, len));
        self.ready.notify_one();
    }
    /// Return a slot the parser has applied. This is what releases reader backpressure, and the
    /// only place `in_flight` falls: an unused reader slot never entered the parser's hands, so
    /// counting it here would let `idle` claim a slot another thread is still parsing was applied.
    fn recycle(&self, slot: Box<[u8]>) {
        let mut shared = self.lock();
        shared.free.push(slot);
        shared.in_flight = shared.in_flight.saturating_sub(1);
        // The parser just ran dry while the reader bridges: interrupt its poll so it publishes now.
        let idle = shared.bridging && shared.in_flight == 0 && shared.ready.is_empty();
        if idle { shared.bridging = false; }
        drop(shared);
        self.space.notify_one();
        if idle && let Some(wake) = &self.idle { wake.signal(); }
    }
    /// Return a slot the reader took but never filled. It was never in flight, so only the free
    /// list changes; the parser's outstanding slots keep their count.
    fn release(&self, slot: Box<[u8]>) {
        let mut shared = self.lock();
        shared.free.push(slot);
        drop(shared);
        self.space.notify_one();
    }
    /// Take the next ready slot when it fits the remaining pass budget, so a slot is never split.
    fn take_ready_up_to(&self, budget: usize) -> Option<(Box<[u8]>, usize)> {
        let mut shared = self.lock();
        if *shared.ready.front().map(|(_, len)| len)? > budget { return None; }
        let (slot, len) = shared.ready.pop_front()?;
        shared.in_flight += 1;
        Some((slot, len))
    }
    /// Wait for a free slot, leaving early when the reader must stop. Called while the master has
    /// readable bytes, so the wait only reflects how far the parser has fallen behind.
    fn wait_space(&self, stopping: impl Fn() -> bool) {
        let mut shared = self.lock();
        while shared.free.is_empty() {
            if stopping() { return; }
            shared = self.space.wait_timeout(shared, Duration::from_millis(RING_WAIT_MS))
                .unwrap_or_else(|poisoned| poisoned.into_inner()).0;
        }
    }
    /// Wait until the parser has applied everything published, so a reply still reaches the
    /// program before the post-exit drain decides it is finished. Bounded by `within`.
    fn wait_parsed(&self, within: Duration) {
        let deadline = Instant::now() + within;
        let mut shared = self.lock();
        while !shared.ready.is_empty() || shared.in_flight > 0 {
            let now = Instant::now();
            if now >= deadline { return; }
            shared = self.space.wait_timeout(shared, deadline - now).unwrap_or_else(|poisoned| poisoned.into_inner()).0;
        }
    }
    /// Wait for a published slot or the reader's end, bounded by `within`.
    fn wait_ready(&self, within: Duration) {
        let deadline = Instant::now() + within;
        let mut shared = self.lock();
        while shared.ready.is_empty() && shared.end.is_none() {
            let now = Instant::now();
            if now >= deadline { return; }
            shared = self.ready.wait_timeout(shared, deadline - now).unwrap_or_else(|poisoned| poisoned.into_inner()).0;
        }
    }
    /// Record why the reader stopped. The first end wins: a drain that ran out of window cannot
    /// replace the real reason with a later one.
    fn end(&self, result: Result<(), String>) {
        let mut shared = self.lock();
        if shared.end.is_none() { shared.end = Some(result); }
        drop(shared);
        self.ready.notify_all();
        self.space.notify_all();
    }
    #[cfg(test)]
    fn ended(&self) -> bool {
        self.lock().end.is_some()
    }
    /// A read failure the reader recorded, if it recorded one.
    fn end_error(&self) -> Option<String> {
        match self.lock().end.clone() { Some(Err(error)) => Some(error), _ => None }
    }
    /// Every published byte has been applied and the reader has stopped.
    fn idle(&self) -> bool {
        let shared = self.lock();
        shared.end.is_some() && shared.ready.is_empty() && shared.in_flight == 0
    }
    /// Test-only: whether a published slot is still waiting for the parser.
    #[cfg(test)]
    fn pending(&self) -> bool {
        !self.lock().ready.is_empty()
    }
    /// Test-only: slots the parser has taken and not returned yet.
    #[cfg(test)]
    fn in_flight(&self) -> usize {
        self.lock().in_flight
    }
}

/// Gather immediately available bytes into one slot, up to its full size. A slot is published when
/// it is full, when a read would block, when the stream ends, when the reader must stop, or before a
/// read failure is reported. Nothing ever waits for a buffer to fill, so a prompt, bell or query
/// still reaches the parser with the reads that produced it.
#[cfg(test)]
fn fill_ring(
    ring: &Ring,
    stopping: impl Fn() -> bool,
    wake: &Wake,
    read: impl FnMut(&mut [u8]) -> Result<Option<usize>, String>,
) -> Result<Fill, String> {
    fill_ring_coalescing(ring, stopping, wake, read, || Bridge::Deliver)
}

/// How a reader's bridge wait ended.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Bridge {
    /// The master has bytes again: keep filling the slot.
    Readable,
    /// Quiet for the poll window, the parser went idle, a stop arrived or the master hung up:
    /// publish what the slot holds.
    Deliver,
}

/// Bytes a slot must hold before a would-block read counts as a refill gap of a saturated stream
/// rather than the end of an interactive burst. macOS hands a PTY master at most 1 KiB per read,
/// so one full read means the writer filled the kernel queue; anything shorter is published at once.
const SATURATED_BYTES: usize = 1024;
/// Immediate re-reads after a would-block on a saturated stream before the reader sleeps in poll.
/// The writer usually refills the queue within microseconds, sooner than a poll sleep and wakeup,
/// so sleeping on every gap would run reader and writer in lockstep at 1 KiB per wakeup.
const BRIDGE_SPINS: usize = 16;
/// One bridge poll: quiet for this long means the burst is over.
const BRIDGE_POLL_MS: libc::c_int = 1;
/// The most time one slot may spend bridging before it is published regardless, well under a frame.
const BRIDGE_BUDGET: Duration = Duration::from_millis(3);

/// [`fill_ring`], plus bridging of a saturated stream's refill gaps. Publishing on every
/// would-block spends a 64 KiB slot, a worker wake and a parse pass on each 1 KiB macOS read, and
/// four such slots stall the reader, and with it the program, behind a 4 KiB backlog. Once a slot
/// holds [`SATURATED_BYTES`], a would-block is retried [`BRIDGE_SPINS`] times, then `bridge` waits
/// for more bytes while the parser is still busy, within [`BRIDGE_BUDGET`] per slot. A short read,
/// an idle parser, a quiet stream or a stop publishes immediately, so interactive output and a
/// program waiting on a reply are never delayed.
fn fill_ring_coalescing(
    ring: &Ring,
    stopping: impl Fn() -> bool,
    wake: &Wake,
    mut read: impl FnMut(&mut [u8]) -> Result<Option<usize>, String>,
    mut bridge: impl FnMut() -> Bridge,
) -> Result<Fill, String> {
    loop {
        if stopping() { return Ok(Fill::Idle); }
        let Some(mut slot) = ring.checkout() else { return Ok(Fill::Full) };
        let mut filled = 0usize;
        let mut spins = 0usize;
        let mut bridge_deadline = None;
        loop {
            match read(&mut slot[filled..]) {
                // The stream ended: the bytes before it are still published, then EOF is reported.
                Ok(Some(0)) => {
                    publish_slot(ring, wake, slot, filled);
                    return Ok(Fill::Ended);
                }
                // Nothing more is readable right now, which is where a tail is published rather
                // than held back for a fuller buffer.
                Ok(None) => {
                    if filled >= SATURATED_BYTES && !stopping() {
                        let now = Instant::now();
                        let deadline = *bridge_deadline.get_or_insert(now + BRIDGE_BUDGET);
                        if now < deadline {
                            if spins < BRIDGE_SPINS {
                                spins += 1;
                                continue;
                            }
                            if ring.begin_bridge() {
                                let outcome = bridge();
                                ring.end_bridge();
                                if outcome == Bridge::Readable && !stopping() { continue; }
                            }
                        }
                    }
                    publish_slot(ring, wake, slot, filled);
                    return Ok(Fill::Idle);
                }
                Ok(Some(count)) => {
                    filled += count;
                    // Each refill gap gets fresh retries within the same slot deadline.
                    spins = 0;
                    if filled == slot.len() {
                        publish_slot(ring, wake, slot, filled);
                        break;
                    }
                    // A stop still publishes what was already gathered.
                    if stopping() {
                        publish_slot(ring, wake, slot, filled);
                        return Ok(Fill::Idle);
                    }
                }
                Err(error) => {
                    // Bytes gathered before the failure are applied instead of dropped with it.
                    publish_slot(ring, wake, slot, filled);
                    return Err(error);
                }
            }
        }
    }
}

/// Publish gathered bytes to the parser, or hand an empty slot straight back to the free list so a
/// reader that found nothing never waits for the parser to return it.
fn publish_slot(ring: &Ring, wake: &Wake, slot: Box<[u8]>, filled: usize) {
    if filled == 0 {
        ring.release(slot);
    } else {
        ring.publish(slot, filled);
        wake.signal();
    }
}

/// Longest the reader sleeps with nothing readable. The wake pipe normally ends the wait, so this
/// only bounds a missed wake and the re-check of the stop and finish flags.
const READER_IDLE_MS: libc::c_int = 250;

/// Why the reader stops: the host closed the pane, the child exited, or the worker unwound. The
/// reader's own wake pipe is separate from the worker's, so a queued command never waits on it.
struct ReaderControl {
    stop: Arc<AtomicBool>,
    finish: Arc<AtomicBool>,
    abandon: Arc<AtomicBool>,
    wake: Arc<Wake>,
}
impl ReaderControl {
    fn stopping(&self) -> bool {
        self.stop.load(Ordering::SeqCst) || self.finish.load(Ordering::SeqCst) || self.abandon.load(Ordering::SeqCst)
    }
    fn signal(&self) {
        self.wake.signal();
    }
}

/// Stage one: the only thread that reads the master. It takes no model lock, writes no reply and
/// issues no ioctl, so a read and a parse overlap by construction and a read never runs with the
/// terminal state held. A close and a child exit both end in a bounded drain that still publishes
/// what the program wrote, then close the ring so the parser can finish.
fn read_loop(fd: i32, ring: &Ring, control: &ReaderControl, wake: &Wake, delivered: &AtomicBool) {
    let mut hung_up = false;
    loop {
        if control.abandon.load(Ordering::SeqCst) {
            // The worker is unwinding: nobody would parse or answer anything read from here.
            ring.end(Ok(()));
            return;
        }
        if control.stop.load(Ordering::SeqCst) {
            // Nobody reads a closed pane, but the shell is usually still writing its last prompt.
            drain_to_quiet(fd, ring, wake);
            ring.end(Ok(()));
            return;
        }
        if control.finish.load(Ordering::SeqCst) {
            ring.end(drain_after_exit(fd, ring, wake, delivered, &control.abandon));
            return;
        }
        let mut poll = [
            libc::pollfd { fd, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: control.wake.read, events: libc::POLLIN, revents: 0 },
        ];
        // SAFETY: poll references two valid pollfds owned by this loop.
        let ready = unsafe { libc::poll(poll.as_mut_ptr(), 2, READER_IDLE_MS) };
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted { continue; }
            ring.end(Err(format!("PTY read failed: {error}")));
            return;
        }
        if poll[1].revents != 0 {
            control.wake.drain();
            // Re-check the flags before touching the descriptor again.
            continue;
        }
        if ready == 0 { continue; }
        hung_up |= poll[0].revents & libc::POLLHUP != 0;
        let stopping = || control.stopping();
        // A bridge wait ends on more output, the parser's idle signal, a control wake or the poll
        // window. Only plain readability keeps filling: the control wake is left pending for the
        // loop above, and a hangup publishes so that loop handles the descriptor.
        let bridge = || {
            let idle = ring.idle_fd().unwrap_or(-1);
            let mut poll = [
                libc::pollfd { fd, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: control.wake.read, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: idle, events: libc::POLLIN, revents: 0 },
            ];
            // SAFETY: poll references three pollfds owned by this frame; a negative fd is ignored.
            let ready = unsafe { libc::poll(poll.as_mut_ptr(), 3, BRIDGE_POLL_MS) };
            let readable = poll[0].revents & libc::POLLIN != 0
                && poll[0].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) == 0;
            if ready > 0 && readable && poll[1].revents == 0 && poll[2].revents == 0 { Bridge::Readable } else { Bridge::Deliver }
        };
        match fill_ring_coalescing(ring, stopping, wake, |buffer| read_pty(fd, buffer, hung_up), bridge) {
            Ok(Fill::Idle) => {}
            // The parser holds every slot: wait for one back before reading the readable bytes.
            Ok(Fill::Full) => ring.wait_space(stopping),
            Ok(Fill::Ended) => {
                // EOF or a hangup can arrive before the worker observes the exit, and a program
                // that just died may still have output in flight. Run the same bounded post-exit
                // drain the child-exit path uses, so a trailing query is published and answered
                // instead of ending the ring on the first empty read.
                ring.end(drain_after_exit(fd, ring, wake, delivered, &control.abandon));
                return;
            }
            Err(error) => {
                ring.end(Err(error));
                return;
            }
        }
    }
}

/// Owns the reader thread. Signalling its wake pipe before the join keeps a close from waiting on
/// a poll, and the drop join keeps the master descriptor alive for the whole reader lifetime.
struct ReaderThread {
    handle: Option<JoinHandle<()>>,
    control: Arc<ReaderControl>,
}
impl ReaderThread {
    fn signal(&self) {
        self.control.signal();
    }
}
impl Drop for ReaderThread {
    fn drop(&mut self) {
        // A panicking worker still has to release the reader before the master closes. This is
        // the reader's own abandon flag: the session-wide stop still means "close", and the
        // clock thread that keeps a timed status running must not see it from here.
        self.control.abandon.store(true, Ordering::SeqCst);
        self.control.signal();
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// Stage two's I/O: the ordered input/reply queue plus the accounting the host and the reader see.
/// One value keeps the pass small and every write in its original order.
struct Pump<'a> {
    model: &'a Arc<Mutex<Model>>,
    ring: &'a Ring,
    output: VecDeque<(Vec<u8>, usize, bool)>,
    response_pending: usize,
    pending: Arc<AtomicUsize>,
    /// Set once a reply byte actually reached the PTY, so the reader's exit drain can keep the
    /// master open long enough for a descendant to read the answer.
    delivered: Arc<AtomicBool>,
    fd: i32,
}

impl Pump<'_> {
    /// Apply terminal bytes and queue the replies they produced. The live loop and both drains go
    /// through here, so the last answers a program asked for before exiting are not discarded
    /// with the parse result. The model lock covers at most [`PARSE_BATCH`] bytes, so a snapshot
    /// or a queued command is never held behind a whole 64 KiB slot.
    fn feed(&mut self, bytes: &[u8]) {
        for piece in bytes.chunks(PARSE_BATCH) {
            let mut state = lock_model(self.model);
            let replies = state.feed(piece);
            queue_parser_replies(&mut state, &mut self.output, &mut self.response_pending, replies);
        }
    }
    /// Consume ready slots for one pass, up to the per-pass budget. Returns whether any byte was
    /// applied, so the worker wakes the host once for the whole batch instead of once per chunk.
    fn parse_pass(&mut self) -> bool {
        let mut budget = MAX_PARSE_PER_PASS;
        let mut fed = false;
        while let Some((slot, len)) = self.ring.take_ready_up_to(budget) {
            self.feed(&slot[..len]);
            self.ring.recycle(slot);
            budget -= len;
            fed |= len > 0;
        }
        fed
    }
    /// Write the front queued buffer once, recording a reply that actually reached the program.
    fn write(&mut self) -> Result<bool, String> {
        let reply = self.output.front().is_some_and(|(_, _, counted)| !counted);
        let wrote = write_front(self.fd, &mut self.output, &mut self.response_pending, &self.pending)?;
        if wrote && reply { self.delivered.store(true, Ordering::SeqCst); }
        Ok(wrote)
    }
    /// Best-effort bounded delivery of the replies still queued (see [`flush_replies`]).
    fn flush(&mut self) -> bool {
        let delivered = flush_replies(self.fd, &mut self.output, &mut self.response_pending, &self.pending);
        if delivered { self.delivered.store(true, Ordering::SeqCst); }
        delivered
    }
    /// Apply published slots until the reader reports its end. Used once the live loop is done: a
    /// post-exit query still reaches the model, and a closing pane still applies the prompt its
    /// shell was writing. With `flush`, each batch is also written, which preserves the old
    /// post-exit behavior where a reply reached the program before the master closed.
    ///
    /// Returns whether the reader really ended. `deadline` is a last-resort safety valve only: the
    /// reader's own drains are bounded, so a healthy reader always ends first. That ordering is
    /// what keeps the final flush from racing a slot that is still being published.
    fn drain_until_end(&mut self, flush: bool, deadline: Instant) -> bool {
        loop {
            if self.parse_pass() && flush { self.flush(); }
            if self.ring.idle() { return true; }
            let now = Instant::now();
            if now >= deadline { return false; }
            self.ring.wait_ready(deadline - now);
        }
    }
}

/// Record final worker state. A clean shutdown keeps an error the host was already shown;
/// only a real IO failure replaces it.
fn finalize(model: &Arc<Mutex<Model>>, exit_code: Option<u32>, io_error: Option<&str>, cleanup_error: Option<&str>) {
    let mut state = lock_model(model);
    state.shell.finish();
    state.exited = true;
    state.exit_code = exit_code;
    if let Some(error) = io_error {
        state.error = Some(error.into());
    } else if state.error.is_none() {
        // A delayed OS reap must not hide the actionable engine failure that
        // stopped the worker. Cleanup errors still surface when no earlier error exists.
        state.error = cleanup_error.map(str::to_owned);
    }
    state.revision = state.revision.saturating_add(1);
    drop(state);
    // A host panic cannot be allowed to leave the session permanently "unavailable": the
    // worker is done, so publish the exit the process actually reached to later polls.
    model.clear_poison();
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
const FLUSH_BLOCKED_PASSES: usize = 20;

/// How long the post-exit drain waits for a still-attached descendant, and how many windows it
/// may wait. The short window catches a query written just after the shell exits; once a reply
/// has actually been delivered, the longer settle window keeps the master open while the
/// descendant consumes it, which is what makes a post-exit reply observable at all.
const DRAIN_IDLE_MS: libc::c_int = 20;
const DRAIN_SETTLE_MS: libc::c_int = 100;
const DRAIN_IDLE_WAITS: usize = 2;

/// A closing host stops reading while the shell is usually still rendering its last prompt, and
/// a write that nobody drains can keep it from ever finishing its exit (the hangup then leaves an
/// unkillable child). A close therefore drains to quiescence first: this many consecutive quiet
/// polls, under this hard cap for a descendant that keeps writing.
const CLOSE_QUIET_MS: libc::c_int = 5;
const CLOSE_QUIET_POLLS: usize = 2;
const CLOSE_DRAIN_MS: u128 = 100;

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
                if unsafe { libc::poll(&mut poll, 1, FLUSH_POLL_MS) } < 0
                    && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
                {
                    return delivered;
                }
                // A timeout spends one blocked pass, not the entire remaining budget.
                // This lets a scheduled reader resume before the bounded flush gives up.
            }
            Err(_) => return delivered,
        }
    }
}

/// Longest the post-exit drain waits for a free slot before it gives up on publishing more.
const DRAIN_SLOT_MS: u64 = 100;
/// Absolute reader budget, leaving the worker time to apply its final published slots.
const POST_EXIT_DRAIN_MS: u64 = 450;
/// Longest the close drain waits for a free slot between reads.
const CLOSE_SLOT_MS: u64 = 50;

/// Read the child's final output after it exits, or after the PTY reports a hangup that can
/// arrive before the exit is observed, and publish it so the parser can answer the queries it
/// still contains. `Err` is an IO failure to record. A descendant that keeps the slave open can
/// never make this run past its bounds, and every published batch is applied before the next
/// idle window starts, so an answer still reaches the program while the master is open.
fn drain_after_exit(fd: i32, ring: &Ring, wake: &Wake, delivered: &AtomicBool, abandon: &AtomicBool) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_millis(POST_EXIT_DRAIN_MS);
    drain_after_exit_with(ring, wake, delivered, deadline, || abandon.load(Ordering::SeqCst), |slot| read_pty(fd, slot, true), |wait| {
        let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        // SAFETY: poll references one valid pollfd for this owned master.
        let ready = unsafe { libc::poll(&mut poll, 1, wait) };
        if ready >= 0 { return Ok(()); }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted { return Ok(()); }
        Err(format!("PTY drain poll failed: {error}"))
    })
}

/// Keep the idle-window policy independent of scheduling so a quiet or interrupted first poll can be
/// tested without racing a writer thread against a short wall-clock delay.
fn drain_after_exit_with<R, P>(
    ring: &Ring, wake: &Wake, delivered: &AtomicBool, deadline: Instant, cancelled: impl Fn() -> bool, mut read: R, mut probe: P,
) -> Result<(), String>
where
    R: FnMut(&mut [u8]) -> Result<Option<usize>, String>,
    P: FnMut(libc::c_int) -> Result<(), String>,
{
    let mut idle_waits = 0;
    for _ in 0..32 {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() || cancelled() { return Ok(()); }
        let Some(mut slot) = ring.checkout_within(remaining.min(Duration::from_millis(DRAIN_SLOT_MS))) else { return Ok(()) };
        match read(&mut slot[..]) {
            Ok(Some(0)) => {
                ring.release(slot);
                return Ok(());
            }
            Ok(None) => {
                // Nothing buffered. A descendant that only noticed the shell exit may still be
                // writing its last query, so wait a short window instead of closing the master
                // on the first empty read. Once a reply has been delivered the descendant needs
                // a longer window to read it before the master disappears with the answer.
                ring.release(slot);
                idle_waits += 1;
                if idle_waits > DRAIN_IDLE_WAITS { return Ok(()); }
                let wait = if delivered.load(Ordering::SeqCst) { DRAIN_SETTLE_MS } else { DRAIN_IDLE_MS };
                // Let the parser apply and answer what was published first: its reply is written
                // in the same pass, so `delivered` reflects this drain rather than a previous one.
                let window = Duration::from_millis(wait as u64);
                ring.wait_parsed(window.min(deadline.saturating_duration_since(Instant::now())));
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() || cancelled() { return Ok(()); }
                // A quiet poll spends one window, rather than bypassing the remaining idle budget.
                // Re-read after either result: readiness can race and a late writer may now have data.
                probe(wait.min(remaining.as_millis() as libc::c_int))?;
            }
            Ok(Some(count)) => {
                idle_waits = 0;
                ring.publish(slot, count);
                wake.signal();
            }
            Err(error) => {
                ring.release(slot);
                return Err(error);
            }
        }
    }
    Ok(())
}

/// Drain the terminal to quiescence before a close hangs the child up, so a prompt the shell was
/// still writing lands instead of leaving that write stuck and the exit unreachable. Bounded:
/// the quiet window ends the drain, and a descendant that keeps writing cannot hold the close
/// open past [`CLOSE_DRAIN_MS`]. Bytes read here are published like any other output, so the
/// closing pane still applies them.
fn drain_to_quiet(fd: i32, ring: &Ring, wake: &Wake) {
    drain_to_quiet_with(
        ring,
        wake,
        || {
            let mut probe = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
            // SAFETY: poll references one valid pollfd for this owned master.
            if unsafe { libc::poll(&mut probe, 1, CLOSE_QUIET_MS) } <= 0 { return None; }
            Some(probe.revents & libc::POLLHUP != 0)
        },
        |buffer, hung_up| read_pty(fd, buffer, hung_up),
    );
}

/// The close drain's policy, separated from the descriptor so a test can drive the exact poll and
/// read sequence. A quiet poll spends one window; a would-block read is not quiet, so the drain
/// polls again and keeps whatever the shell writes next.
fn drain_to_quiet_with<P, R>(ring: &Ring, wake: &Wake, mut probe: P, mut read: R)
where
    P: FnMut() -> Option<bool>,
    R: FnMut(&mut [u8], bool) -> Result<Option<usize>, String>,
{
    let started = Instant::now();
    let mut quiet = 0usize;
    while started.elapsed().as_millis() < CLOSE_DRAIN_MS {
        let Some(hung_up) = probe() else {
            quiet += 1;
            if quiet >= CLOSE_QUIET_POLLS { return; }
            continue;
        };
        quiet = 0;
        for _ in 0..RING_SLOTS {
            let Some(mut slot) = ring.checkout_within(Duration::from_millis(CLOSE_SLOT_MS)) else { return };
            match read(&mut slot[..], hung_up) {
                Ok(Some(count)) => {
                    if count == 0 {
                        // The stream ended: nothing is left to keep the shell's final write from
                        // completing.
                        ring.release(slot);
                        return;
                    }
                    ring.publish(slot, count);
                    wake.signal();
                }
                // A would-block read is not the end. The shell is often between two writes of its
                // final prompt, so keep the bounded quiet policy and poll again instead of giving
                // up on output that is about to land.
                Ok(None) => {
                    ring.release(slot);
                    break;
                }
                Err(_) => {
                    ring.release(slot);
                    return;
                }
            }
        }
    }
}

/// Longest the worker may sleep with nothing pending. Input and shutdown wake it through the
/// self-pipe, so this only bounds silent child-exit detection.
const IDLE_POLL_MS: libc::c_int = 250;
/// Worker budget for the post-exit drain and applying the reader's final slots.
const POST_EXIT_WAIT_MS: u64 = 500;
/// How long a closing worker waits for the reader's bounded quiet drain. Both are bounded, so
/// this only keeps close from returning before the shell's final write landed.
const CLOSE_WAIT_MS: u64 = 500;
/// A blocked write still retries at the old cadence, so a reply is not held for a whole idle poll.
const BLOCKED_WRITE_POLL_MS: libc::c_int = 10;
/// Longest a busy loop goes without checking whether the child exited.
const WAIT_INTERVAL_MS: u128 = 100;
/// Commands drained per pass; finishing a full batch signals another pass so nothing waits.
const MAX_COMMANDS_PER_PASS: usize = 256;

/// Poll timeout: the next parser deadline, clamped to the idle bound, rounded up so a
/// sub-millisecond remainder is not dropped.
fn poll_timeout(deadline: Option<Instant>) -> libc::c_int {
    let Some(deadline) = deadline else { return IDLE_POLL_MS };
    let now = Instant::now();
    if deadline <= now { return 0; }
    let millis = deadline.saturating_duration_since(now).as_millis().saturating_add(1);
    millis.min(IDLE_POLL_MS as u128) as libc::c_int
}

/// Split one drained batch into the input to queue and the single resize to apply. Every resize
/// but the last would reflow the grid for a geometry nobody can observe, so only the final one
/// survives; inputs keep their relative order.
fn coalesce(batch: Vec<Command>) -> (Vec<Vec<u8>>, Option<Size>) {
    let mut inputs = Vec::with_capacity(batch.len());
    let mut resize = None;
    for command in batch {
        match command {
            Command::Input(bytes) => inputs.push(bytes),
            Command::Resize(size) => resize = Some(size),
            // The run loop panics before coalescing, but the match must still be exhaustive.
            #[cfg(test)]
            Command::Panic => {}
        }
    }
    (inputs, resize)
}

fn run(
    master: Box<dyn portable_pty::MasterPty + Send>,
    mut child: ChildGuard,
    rx: mpsc::Receiver<Command>,
    model: Arc<Mutex<Model>>,
    stop: Arc<AtomicBool>,
    pending: Arc<AtomicUsize>,
    Wakes { wake, notify }: Wakes,
) -> Result<(), String> {
    let fd = master.as_raw_fd().ok_or("PTY descriptor missing")?;
    let ring = Arc::new(Ring::with_idle_wake()?);
    let finish = Arc::new(AtomicBool::new(false));
    let delivered = Arc::new(AtomicBool::new(false));
    // The reader gets its own wake pipe: it must never drain the worker's, or a queued command
    // would wait for the idle poll.
    let control = Arc::new(ReaderControl {
        stop: stop.clone(),
        finish: finish.clone(),
        abandon: Arc::new(AtomicBool::new(false)),
        wake: Arc::new(Wake::new()?),
    });
    let reader = {
        let (ring, control, thread_control, wake, delivered) =
            (ring.clone(), control.clone(), control.clone(), wake.clone(), delivered.clone());
        let handle = thread::Builder::new()
            .name("akitty-pty-read".into())
            .spawn(move || read_loop(fd, &ring, &thread_control, &wake, &delivered))
            .map_err(|e| format!("cannot start PTY reader: {e}"))?;
        // A panic below still releases the reader before the master descriptor closes.
        ReaderThread { handle: Some(handle), control }
    };
    let mut pump = Pump {
        model: &model,
        ring: &ring,
        output: VecDeque::new(),
        response_pending: 0,
        pending,
        delivered: delivered.clone(),
        fd,
    };
    let mut io_error = None;
    let mut last_wait = Instant::now();
    let mut chrome_signalled = None;
    while !stop.load(Ordering::SeqCst) {
        let deadline = expire_and_queue(&model, &mut pump.output, &mut pump.response_pending, &notify, &mut chrome_signalled);
        let batch: Vec<Command> = rx.try_iter().take(MAX_COMMANDS_PER_PASS).collect();
        // Test-only: unwind with the state held, exactly like a parser panic during model.feed.
        #[cfg(test)]
        if batch.iter().any(|command| matches!(command, Command::Panic)) {
            let _held = lock_model(&model);
            panic!("test: PTY engine panic while holding the terminal state");
        }
        if batch.len() == MAX_COMMANDS_PER_PASS {
            // More commands wait in the channel, so keep the next poll from sleeping on them.
            wake.signal();
        }
        let (inputs, resize) = coalesce(batch);
        for bytes in inputs {
            pump.output.push_back((bytes, 0, true));
        }
        if let Some(size) = resize {
            // The cell size is read before the ioctl so TIOCGWINSZ sees it.
            let cell = lock_model(&model).cell_px;
            if let Err(error) = master.resize(pty_size(size, cell)) {
                io_error = Some(error.to_string());
                break;
            }
            let mut state = lock_model(&model);
            state.resize_grid(size);
            state.size = size;
            state.revision += 1;
            drop(state);
            // A resize reflows rows the host has not seen; it is a host-visible revision.
            notify.signal();
        }
        // Stage two applies the whole published batch here, so the host is woken once for it
        // instead of once per parsed chunk. Each model lock still covers at most `PARSE_BATCH`.
        if pump.parse_pass() {
            notify.signal();
        }
        // Every published byte is applied and the reader has stopped: no output can follow.
        if ring.idle() { break; }
        let mut poll = [
            libc::pollfd {
                fd,
                events: if pump.output.is_empty() { 0 } else { libc::POLLOUT },
                revents: 0,
            },
            libc::pollfd { fd: wake.read, events: libc::POLLIN, revents: 0 },
        ];
        let timeout = if pump.output.is_empty() {
            poll_timeout(deadline)
        } else {
            poll_timeout(deadline).min(BLOCKED_WRITE_POLL_MS)
        };
        // SAFETY: poll references two valid pollfds owned by this loop.
        let ready = unsafe { libc::poll(poll.as_mut_ptr(), 2, timeout) };
        if ready < 0 {
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                io_error = Some(std::io::Error::last_os_error().to_string());
                break;
            }
            continue;
        }
        if poll[1].revents != 0 { wake.drain(); }
        if poll[0].revents & libc::POLLOUT != 0
            && let Err(error) = pump.write()
        {
            io_error = Some(error);
            break;
        }
        let timed_out = ready == 0;
        // Only the reader touches the master read side; a hangup reaches us as the ring's end.
        // waitpid does not run on every pass: a hangup or an idle poll checks at once, and a pass
        // kept busy by output (a background job still writing after the shell exited) checks at
        // most every WAIT_INTERVAL_MS.
        if timed_out || last_wait.elapsed().as_millis() >= WAIT_INTERVAL_MS {
            last_wait = Instant::now();
            match child.try_wait() {
                Ok(Some(status)) => {
                    let mut state = lock_model(&model);
                    state.exited = true;
                    state.exit_code = Some(status.exit_code());
                    state.revision += 1;
                    drop(state);
                    // `exited` is the one change no further output will announce.
                    notify.signal();
                    break;
                }
                Ok(None) => {}
                Err(error) => {
                    io_error = Some(error.to_string());
                    break;
                }
            }
        }
    }
    // Keep applying slots while the reader drains, so it cannot get stuck waiting for a free slot.
    // A natural exit also delivers replies while the master is still open for descendants.
    let closing = stop.load(Ordering::SeqCst);
    let wait = if closing {
        CLOSE_WAIT_MS
    } else {
        finish.store(true, Ordering::SeqCst);
        POST_EXIT_WAIT_MS
    };
    reader.signal();
    let drained = pump.drain_until_end(!closing, Instant::now() + Duration::from_millis(wait));
    // Join before inspecting the final error or closing the descriptor. If the worker timed out,
    // apply the at most one ring's worth the reader could still publish on its way out.
    drop(reader);
    if !drained { pump.parse_pass(); }
    if !closing { pump.flush(); }
    if let Some(error) = ring.end_error() { io_error = Some(error); }
    let cleanup_error = child.finish().err();
    finalize(&model, child.exit_code(), io_error.as_deref(), cleanup_error.as_deref());
    // `finalize` is the last revision bump; a missed exit would strand the pane's status.
    notify.signal();
    drop(master);
    if let Some(error) = io_error.or(cleanup_error) {
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
        let first: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        let since = first["revision"].as_u64();
        session.set_cell_size(10, 20).unwrap();
        let second: Value = serde_json::from_str(&session.snapshot(since, true, false).unwrap()).unwrap();
        // The new pixel size feeds placeholder geometry, so a same-revision poll must
        // still report a change instead of serving the stale placeholder layout.
        assert_eq!(second["changed"], true, "{second}");
        assert_eq!(session.model.lock().unwrap().cell_px, (10, 20));
    }

    #[test]
    fn shell_state_of_an_exited_pane_reports_only_final_program_records() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]7501;state=working\x07\x07").unwrap();
        session.model.lock().unwrap().exited = true;
        let state = session.shell_state().unwrap();
        assert_eq!(state["exited"], true, "{state}");
        let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(state["program_status"], snapshot["program_status"], "{state}");
        // The read took no snapshot event: the bell went to the snapshot.
        assert_eq!(snapshot["bell"], true, "{snapshot}");
    }

    #[test]
    fn oversized_snapshot_keeps_events_and_forces_a_full_retry() {
        let session = Session::new(20, 4, None, None, true, 5000, None).unwrap();
        session.feed(b"hello").unwrap();
        let since = serde_json::from_str::<Value>(&session.snapshot(None, true, false).unwrap()).unwrap()["revision"].as_u64();
        // One changed row plus queued events: against the retained base this poll would be a partial diff.
        session.feed(b"world\x07\x1b]52;c;aGk=\x07").unwrap();
        // The bound is injected, so the fixed production message is what the branch returns.
        let error = session.snapshot_within(since, true, false, 16).unwrap_err();
        assert_eq!(error, "snapshot exceeds 8 MiB", "{error}");
        // Nothing was committed, so the one-shot events ride the next successful poll.
        let next: Value = serde_json::from_str(&session.snapshot(since, true, false).unwrap()).unwrap();
        assert_eq!(next["bell"], true, "{next}");
        assert_eq!(next["clipboard"], json!(["hi"]), "{next}");
        assert!(next["lines"][0].as_str().unwrap().starts_with("helloworld"), "{next}");
        // The discarded base forces a full snapshot rather than a diff against it.
        assert_eq!(next.get("partial"), None, "{next}");
        // Control: the full commit restored a base, so a one-row change diffs again.
        let revision = next["revision"].as_u64();
        session.feed(b"z").unwrap();
        let partial: Value = serde_json::from_str(&session.snapshot(revision, true, false).unwrap()).unwrap();
        assert_eq!(partial["partial"], true, "{partial}");
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
    fn injected_commands_clear_typeahead_from_the_prompt_first() {
        let mut session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        let (tx, rx) = mpsc::sync_channel(4);
        session.commands = Some(tx);
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let authorization = session.command_authorize(lease, "echo hi".into(), None).unwrap()["authorization"].as_u64().unwrap();
        session.command_execute(lease, authorization, "echo hi".into()).unwrap();
        assert!(matches!(rx.try_recv(), Ok(Command::Input(bytes)) if bytes == b"\x15echo hi\r"));
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
    fn oversized_completion_report_never_consumes_the_pending_command() {
        let mut session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        let (tx, rx) = mpsc::sync_channel(4);
        session.commands = Some(tx);
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let authorization = session.command_authorize(lease, "echo hi".into(), None).unwrap()["authorization"].as_u64().unwrap();
        session.command_execute(lease, authorization, "echo hi".into()).unwrap();
        assert!(matches!(rx.try_recv(), Ok(Command::Input(_))));
        // Rejected oversized metadata must not observe the dispatched command's completion
        // through its truncated prefix.
        let mut oversized = b"\x1b]133;D".to_vec();
        oversized.extend(vec![b'x'; 70_000]);
        oversized.push(0x07);
        session.model.lock().unwrap().feed(&oversized);
        let audit = session.control_audit(0).unwrap();
        let events: Vec<&str> = audit["events"].as_array().unwrap().iter().filter_map(|e| e["event"].as_str()).collect();
        assert!(events.contains(&"dispatched"), "{audit}");
        assert!(!events.contains(&"shell_completion_observed_untrusted"), "{audit}");
        // The genuine completion that follows is still observed.
        session.model.lock().unwrap().feed(b"\x1b]133;D;0\x07");
        let audit = session.control_audit(0).unwrap();
        let events: Vec<&str> = audit["events"].as_array().unwrap().iter().filter_map(|e| e["event"].as_str()).collect();
        assert!(events.contains(&"shell_completion_observed_untrusted"), "{audit}");
    }

    #[test]
    fn rejected_control_operations_leave_the_snapshot_revision_unchanged() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let first: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        let since = first["revision"].as_u64();
        let unchanged = |session: &Session| {
            let snapshot: Value = serde_json::from_str(&session.snapshot(since, true, false).unwrap()).unwrap();
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
        let denied: Value = serde_json::from_str(&session.snapshot(since, true, false).unwrap()).unwrap();
        assert_eq!(denied["changed"], true, "{denied}");
        session.control_release(Some(lease)).unwrap();
        let released: Value = serde_json::from_str(&session.snapshot(since, true, false).unwrap()).unwrap();
        assert_eq!(released["changed"], true, "{released}");
    }

    #[test]
    fn stale_authorize_leaves_the_snapshot_revision_unchanged() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let first: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        let since = first["revision"].as_u64();
        // A stale lease fails before any audit append, so the snapshot must stay unchanged.
        assert!(session.command_authorize(lease + 1, "echo hi".into(), None).is_err());
        let stale: Value = serde_json::from_str(&session.snapshot(since, true, false).unwrap()).unwrap();
        assert_eq!(stale["changed"], false, "{stale}");
        // A failure that does append audit must still reach the host through a new revision.
        assert!(session.command_authorize(lease, "\u{1}".into(), None).is_err());
        let rejected: Value = serde_json::from_str(&session.snapshot(since, true, false).unwrap()).unwrap();
        assert_eq!(rejected["changed"], true, "{rejected}");
    }

    #[test]
    fn stale_execute_leaves_the_snapshot_revision_unchanged() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x1b]133;A\x07").unwrap();
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let first: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        let since = first["revision"].as_u64();
        // A stale lease fails before consume, so the snapshot must stay unchanged.
        assert!(session.command_execute(lease + 1, 1, "echo hi".into()).is_err());
        let stale: Value = serde_json::from_str(&session.snapshot(since, true, false).unwrap()).unwrap();
        assert_eq!(stale["changed"], false, "{stale}");
        // A rejected dispatch would append dispatch_failed; a stale lease never reaches it.
        let audit = session.control_audit(0).unwrap();
        let events: Vec<&str> = audit["events"].as_array().unwrap().iter().filter_map(|e| e["event"].as_str()).collect();
        assert!(!events.contains(&"dispatch_failed"), "{audit}");
        // A grant mismatch does append audit, so it must still invalidate the snapshot.
        let authorization = session.command_authorize(lease, "echo hi".into(), None).unwrap()["authorization"].as_u64().unwrap();
        let baseline: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        let baseline = baseline["revision"].as_u64();
        assert!(session.command_execute(lease, authorization, "echo nope".into()).is_err());
        let mismatch: Value = serde_json::from_str(&session.snapshot(baseline, true, false).unwrap()).unwrap();
        assert_eq!(mismatch["changed"], true, "{mismatch}");
    }

    #[test]
    fn wake_pipe_is_nonblocking_close_on_exec_and_drains_after_a_signal() {
        let wake = Wake::new().unwrap();
        for fd in [wake.read, wake.write] {
            // SAFETY: fd is a descriptor this Wake owns, so reading its flags is sound.
            let status = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            assert!(status & libc::O_NONBLOCK != 0, "{fd} must never block");
            // SAFETY: same descriptor; F_GETFD reports the close-on-exec flag.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            assert!(flags & libc::FD_CLOEXEC != 0, "{fd} must not leak into the shell");
        }
        let mut poll = libc::pollfd { fd: wake.read, events: libc::POLLIN, revents: 0 };
        // SAFETY: poll references one valid pollfd this test owns.
        assert_eq!(unsafe { libc::poll(&mut poll, 1, 0) }, 0);
        wake.signal();
        wake.signal();
        // SAFETY: same pollfd, now with two pending bytes on the pipe.
        assert_eq!(unsafe { libc::poll(&mut poll, 1, 0) }, 1);
        wake.drain();
        // SAFETY: same pollfd after the drain.
        assert_eq!(unsafe { libc::poll(&mut poll, 1, 0) }, 0, "drain must consume every wake");
    }

    #[test]
    fn queued_input_signals_the_wake_pipe_and_a_rejected_send_does_not() {
        let mut session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (tx, rx) = mpsc::sync_channel(1);
        let wake = Arc::new(Wake::new().unwrap());
        session.commands = Some(tx);
        session.wake = Some(wake.clone());
        let mut poll = libc::pollfd { fd: wake.read, events: libc::POLLIN, revents: 0 };
        session.input_bytes(b"x".to_vec()).unwrap();
        // SAFETY: poll references one valid pollfd this test owns.
        assert_eq!(unsafe { libc::poll(&mut poll, 1, 0) }, 1, "input must wake the worker");
        wake.drain();
        // Fill the bounded queue without waking, then require the rejection to stay silent.
        assert!(matches!(rx.try_recv(), Ok(Command::Input(bytes)) if bytes == b"x"));
        session.commands.as_ref().unwrap().try_send(Command::Input(vec![0])).unwrap();
        assert!(session.input_bytes(b"y".to_vec()).is_err());
        // SAFETY: same valid pollfd after the rejected send.
        assert_eq!(unsafe { libc::poll(&mut poll, 1, 0) }, 0, "a rejected send must not wake");
    }

    #[test]
    fn input_bumps_the_revision_once_on_success_and_never_on_rejection() {
        let mut session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (tx, _rx) = mpsc::sync_channel(4);
        session.commands = Some(tx);
        let before = lock_model(&session.model).revision;
        session.input_bytes(b"x".to_vec()).unwrap();
        assert_eq!(lock_model(&session.model).revision, before + 1, "one accepted input is one revision");
        // An agent lease blocks human typing; the failed attempt must not invalidate snapshots.
        let lease = session.control_acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let before = lock_model(&session.model).revision;
        assert!(session.input_bytes(b"y".to_vec()).is_err());
        assert_eq!(lock_model(&session.model).revision, before);
        session.control_release(Some(lease)).unwrap();
        // Empty input never reaches the PTY and changes nothing, so it earns no revision either.
        let before = lock_model(&session.model).revision;
        session.input_bytes(Vec::new()).unwrap();
        assert_eq!(lock_model(&session.model).revision, before);
    }

    #[test]
    fn a_command_batch_keeps_only_the_last_resize_and_every_input() {
        let first = Size::validate(30, 5).unwrap();
        let last = Size::validate(40, 6).unwrap();
        let (inputs, resize) = coalesce(vec![
            Command::Input(b"a".to_vec()),
            Command::Resize(first),
            Command::Input(b"b".to_vec()),
            Command::Resize(last),
            Command::Input(b"c".to_vec()),
        ]);
        assert_eq!(inputs, vec![b"a".to_vec(), b"b".to_vec(), b"c".to_vec()]);
        assert_eq!(resize.map(|size| (size.cols, size.rows)), Some((40, 6)));
        assert!(coalesce(vec![Command::Input(b"a".to_vec())]).1.is_none());
    }

    #[test]
    fn poll_timeout_uses_the_deadline_but_never_exceeds_the_idle_bound() {
        assert_eq!(poll_timeout(None), IDLE_POLL_MS);
        // A deadline already past must not sleep at all.
        assert_eq!(poll_timeout(Some(Instant::now() - std::time::Duration::from_millis(1))), 0);
        // A far deadline is clamped so a silent child exit is still observed.
        assert_eq!(poll_timeout(Some(Instant::now() + std::time::Duration::from_secs(60))), IDLE_POLL_MS);
        // A close deadline is honoured, rounded up to whole milliseconds.
        let timeout = poll_timeout(Some(Instant::now() + std::time::Duration::from_millis(20)));
        assert!((1..=21).contains(&timeout), "{timeout}");
    }

    #[test]
    fn a_poisoned_model_still_reports_the_exit() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let poisoned = session.model.clone();
        let _ = std::thread::spawn(move || {
            let _guard = poisoned.lock().unwrap();
            panic!("host panic while holding the terminal state");
        })
        .join();
        assert!(session.model.lock().is_err(), "the panic must poison the lock");
        // The worker's exit path recovers the state instead of stranding the session.
        finalize(&session.model, Some(0), None, None);
        let state = lock_model(&session.model);
        assert!(state.exited);
        assert_eq!(state.exit_code, Some(0));
        drop(state);
        // Later host polls must work again, so the exit is actually observable.
        assert!(session.snapshot(None, true, false).is_ok());
    }

    /// Panic while holding the model lock, as a host-side engine step would.
    fn poison(model: &Arc<Mutex<Model>>) {
        let poisoned = model.clone();
        let _ = std::thread::spawn(move || {
            let _guard = poisoned.lock().unwrap();
            panic!("host panic while holding the terminal state");
        })
        .join();
    }

    #[test]
    fn a_host_poison_fails_closed_and_the_next_poll_reports_the_exit() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        poison(&session.model);
        // The next host call names the actionable failure instead of "terminal unavailable".
        assert_eq!(session.input_bytes(b"x".to_vec()).unwrap_err(), ENGINE_FAILED);
        // Headless recovery finalizes at once, so the exit is visible on the very next poll.
        let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(snapshot["exited"], true, "{snapshot}");
        assert_eq!(snapshot["error"], ENGINE_FAILED, "{snapshot}");
    }

    #[test]
    fn a_poisoned_pty_session_stops_the_worker_and_stays_observable() {
        let session = Session::new(40, 8, Some("/bin/sh".into()), Some("/tmp".into()), false, 5000, None).unwrap();
        session.input_bytes(b"printf '\\033]2;PID:%s\\007' $$\r".to_vec()).unwrap();
        let ready_deadline = Instant::now() + std::time::Duration::from_secs(10);
        let pid = loop {
            let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
            if let Some(pid) = snapshot["title"].as_str().and_then(|s| s.strip_prefix("PID:")).and_then(|s| s.parse::<i32>().ok()) {
                assert!(pid > 1); break pid;
            }
            assert!(Instant::now() < ready_deadline, "the fixture shell never became ready");
            std::thread::sleep(std::time::Duration::from_millis(5));
        };
        poison(&session.model);
        // The PTY session has no worker to finalize until it is told to stop.
        assert_eq!(session.scroll(1).unwrap_err(), ENGINE_FAILED);
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        loop {
            match session.snapshot(None, true, false) {
                Ok(json) => {
                    let snapshot: Value = serde_json::from_str(&json).unwrap();
                    assert_eq!(snapshot["exited"], true, "{snapshot}");
                    assert_eq!(snapshot["error"], ENGINE_FAILED, "{snapshot}");
                    break;
                }
                Err(error) => {
                    // Until the worker finalizes, the poison is still present.
                    assert_eq!(error, ENGINE_FAILED, "{error}");
                    assert!(Instant::now() < deadline, "the worker never finalized after the poison");
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
            }
        }
        if let Err(error) = session.close() {
            assert_eq!(error, "terminal child did not exit within 1 second; cleanup continues in background");
        }
        let cleanup_deadline = Instant::now() + std::time::Duration::from_secs(10);
        loop {
            // SAFETY: signal zero only checks this test-owned child's lifetime.
            if unsafe { libc::kill(pid, 0) } == -1 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) { break; }
            assert!(Instant::now() < cleanup_deadline, "the poisoned session's child was not reaped");
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    #[test]
    fn a_worker_panic_with_output_in_flight_still_exits_bounded() {
        let dir = std::env::temp_dir().join(format!("akitty-panic-inflight-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let pid_file = dir.join("shell.pid");
        let script = dir.join("shell.sh");
        // Report the pid, then keep writing: the ring holds published output when the panic hits,
        // so the reader must be released and joined without waiting for that backlog to drain.
        std::fs::write(
            &script,
            format!("#!/bin/sh\nprintf '%s\\n' \"$$\" > '{}'\nwhile :; do printf 'busy\\n'; done\n", pid_file.display()),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let session = Session::new(40, 8, Some(script.to_string_lossy().into_owned()), Some("/tmp".into()), false, 5000, None).unwrap();
        let pid = {
            let deadline = Instant::now() + std::time::Duration::from_secs(5);
            loop {
                if let Ok(pid) = std::fs::read_to_string(&pid_file).unwrap_or_default().trim().parse::<i32>() { break pid; }
                assert!(Instant::now() < deadline, "the fixture shell never reported its pid");
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        };
        // Wait for real output to reach the model, so the panic lands with slots in flight.
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        while !session.snapshot(None, true, false).unwrap().contains("busy") {
            assert!(Instant::now() < deadline, "the fixture never wrote output");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        session.commands.as_ref().unwrap().try_send(Command::Panic).unwrap();
        session.wake();
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let state = lock_model(&session.model);
            if state.exited {
                assert_eq!(state.error.as_deref(), Some(ENGINE_FAILED));
                break;
            }
            drop(state);
            assert!(Instant::now() < deadline, "the panicking worker never finalized");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        while unsafe { libc::kill(pid, 0) } == 0 {
            assert!(Instant::now() < deadline, "the shell survived a worker panic with output in flight");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let started = Instant::now();
        let _ = session.close();
        assert!(started.elapsed() < std::time::Duration::from_secs(2), "close waited on a panicked worker: {:?}", started.elapsed());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_poison_after_the_shell_exited_is_cleared_and_keeps_the_exit_code() {
        let session = Session::new(40, 8, Some("/bin/sh".into()), Some("/tmp".into()), false, 5000, None).unwrap();
        session.input("exit 3\r".into(), false).unwrap();
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        while !lock_model(&session.model).exited {
            assert!(Instant::now() < deadline, "the shell did not exit");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        // Give the worker time to run its one finalize; a later poison has no worker left to clear it.
        std::thread::sleep(std::time::Duration::from_millis(100));
        poison(&session.model);
        assert_eq!(session.scroll(1).unwrap_err(), ENGINE_FAILED);
        let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(snapshot["exited"], true, "{snapshot}");
        assert_eq!(snapshot["exit_code"], 3, "the real exit code must survive the recovery: {snapshot}");
        assert_eq!(snapshot["error"], ENGINE_FAILED, "{snapshot}");
        session.close().unwrap();
    }

    #[test]
    fn a_worker_panic_leaves_an_exited_restartable_session() {
        let dir = std::env::temp_dir().join(format!("akitty-worker-panic-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let pid_file = dir.join("shell.pid");
        let script = dir.join("shell.sh");
        // Report the pid before idling, so the test can prove the child died with the worker.
        std::fs::write(
            &script,
            format!("#!/bin/sh\nprintf '%s\\n' \"$$\" > '{}'\nexec /bin/sleep 30\n", pid_file.display()),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let session = Session::new(30, 8, Some(script.to_string_lossy().into_owned()), Some("/tmp".into()), false, 5000, None).unwrap();
        let pid = {
            let deadline = Instant::now() + std::time::Duration::from_secs(5);
            loop {
                if let Ok(pid) = std::fs::read_to_string(&pid_file).unwrap_or_default().trim().parse::<i32>() {
                    break pid;
                }
                assert!(Instant::now() < deadline, "the fixture shell never reported its pid");
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        };
        session.commands.as_ref().unwrap().try_send(Command::Panic).unwrap();
        session.wake();
        // The caught panic publishes the failure and marks the pane exited.
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let state = lock_model(&session.model);
            if state.exited {
                assert_eq!(state.error.as_deref(), Some(ENGINE_FAILED));
                break;
            }
            drop(state);
            assert!(Instant::now() < deadline, "the worker panic was never finalized");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        // ChildGuard's Drop runs while the worker unwinds, so the shell must be gone.
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        while unsafe { libc::kill(pid, 0) } == 0 {
            assert!(Instant::now() < deadline, "the shell survived a worker panic");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        // Later host calls work, and close must not wait on the dead worker.
        assert!(session.snapshot(None, true, false).is_ok());
        // The thread outlives the panic as the pane's clock: a timed status still clears on time.
        let notify = session.notify.clone().unwrap();
        let expires = chrome::now_ms() + 200;
        let input = serde_json::from_value(json!({"status":{"text":"Failed","tone":"error","expires":expires}})).unwrap();
        session.set_chrome(input).unwrap();
        assert!(session.snapshot(None, true, false).is_ok());
        notify.drain();
        let mut poll = libc::pollfd { fd: notify.read_fd(), events: libc::POLLIN, revents: 0 };
        let waited = Instant::now();
        assert_eq!(unsafe { libc::poll(&mut poll, 1, 900) }, 1, "a timed status after a panic never woke the host");
        assert!(waited.elapsed() < std::time::Duration::from_millis(700), "woke after {:?}", waited.elapsed());
        let started = Instant::now();
        let _ = session.close();
        assert!(started.elapsed() < std::time::Duration::from_secs(2), "close waited on the panicked worker");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_poisoned_snapshot_serializer_still_serializes() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = session.snapshot_lock.lock().unwrap();
            panic!("host panic during snapshot serialization");
        }));
        assert!(session.snapshot_lock.lock().is_err(), "the serializer panic must poison the lock");
        // The lock guards no data, so a poisoned serializer must not block later snapshots.
        assert!(session.snapshot(None, true, false).is_ok());
    }

    #[test]
    fn a_resize_storm_applies_the_final_grid() {
        let session = Session::new(20, 3, Some("/bin/sh".into()), Some("/tmp".into()), false, 5000, None).unwrap();
        let sizes = [(41, 7), (42, 8), (43, 9), (60, 12)];
        for (cols, rows) in sizes {
            session.resize(cols, rows).unwrap();
        }
        let last = *sizes.last().unwrap();
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let applied = { let state = lock_model(&session.model); (state.size.cols, state.size.rows) };
            if applied == last { break; }
            assert!(Instant::now() < deadline, "the worker never applied the final grid: {applied:?}");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    #[test]
    fn keystrokes_echo_without_waiting_for_the_idle_poll() {
        // The tty line discipline echoes printable input back through the master without any
        // program involvement. An interactive login shell can redraw or scroll away matching
        // characters, so counting letters in its JSON snapshot is not an echo acknowledgement.
        let shell = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/echo.sh");
        let session = Session::new(80, 6, Some(shell.into()), Some("/tmp".into()), false, 5000, None).unwrap();
        let wait_for = |row: usize, text: &str| {
            let deadline = Instant::now() + std::time::Duration::from_secs(5);
            while Instant::now() < deadline {
                let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
                if snapshot["lines"][row].as_str().is_some_and(|line| line.trim_end() == text) { return true; }
                assert_ne!(snapshot["exited"], true, "echo fixture exited: {snapshot}");
                std::thread::yield_now();
            }
            false
        };
        // Readiness follows stty, so startup timing cannot swallow the first measured byte.
        assert!(wait_for(0, "ECHO_READY"), "echo fixture never became ready");
        // The whole line fits without wrapping. Match its exact contents, excluding metadata,
        // banners and prompts, so a coincidental character cannot satisfy or mask an echo.
        let markers: Vec<char> = ('A'..='Z').chain('a'..='j').collect();
        let mut samples = Vec::with_capacity(markers.len());
        let mut typed = String::new();
        for marker in markers {
            typed.push(marker);
            let start = Instant::now();
            session.input_bytes(marker.to_string().into_bytes()).unwrap();
            assert!(wait_for(1, &typed), "no echo for {typed:?}");
            samples.push(start.elapsed());
        }
        samples.sort();
        let median = samples[samples.len() / 2];
        // The wake pipe delivers the echo on the next poll (about 1 ms here). Without it input waits
        // for the 250 ms idle poll; the bound sits far from both so a loaded CI host cannot flake it.
        assert!(median < std::time::Duration::from_millis(50), "median echo latency {median:?}");
    }

    #[test]
    fn read_image_returns_the_frame_on_display_after_an_animation_advance() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        // 2x1 RGBA: red | green.
        session.feed(b"\x1b_Ga=t,f=32,s=2,v=1,i=1,q=2;/wAA/wD/AP8=\x1b\\").unwrap();
        let mut out = [0u8; 8];
        assert_eq!(session.read_image(1, &mut out), 8);
        assert_eq!(out, [255, 0, 0, 255, 0, 255, 0, 255]);
        // Frame 2 copies frame 1 and overwrites the left pixel; showing it changes what read_image hands out.
        session.feed(b"\x1b_Ga=f,i=1,c=1,x=0,s=1,v=1,X=1,q=2;AP8A/w==\x1b\\").unwrap();
        session.feed(b"\x1b_Ga=a,i=1,c=2\x1b\\").unwrap();
        let mut shown = [0u8; 8];
        assert_eq!(session.read_image(1, &mut shown), 8);
        assert_eq!(shown, [0, 255, 0, 255, 0, 255, 0, 255], "the shown frame, not the transmitted one");
        // A buffer that cannot hold the image, or an id that names nothing, reads nothing.
        assert_eq!(session.read_image(1, &mut [0u8; 7]), 0);
        assert_eq!(session.read_image(9, &mut shown), 0);
    }

    #[test]
    fn a_second_status_expiring_before_the_next_worker_pass_still_wakes_the_host() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let show = |text: &str| {
            let expires = chrome::now_ms() + 30;
            let input = serde_json::from_value(json!({"status":{"text":text,"tone":"info","expires":expires}})).unwrap();
            session.set_chrome(input).unwrap();
            let shown: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
            assert!(shown.to_string().contains(text), "the host received {text}: {shown}");
            std::thread::sleep(std::time::Duration::from_millis(60));
        };
        let mut signalled = None;
        show("first");
        assert!(chrome_tick(&lock_model(&session.model), &mut signalled).0, "the first expiry wakes the host");
        assert!(!chrome_tick(&lock_model(&session.model), &mut signalled).0, "one wake per delivered status");
        // The host clears the first status, then receives and outlives a second one, all before
        // the worker's next pass.
        session.snapshot(None, true, false).unwrap();
        show("second");
        assert!(chrome_tick(&lock_model(&session.model), &mut signalled).0, "the second expiry must wake the host too");
    }

    #[test]
    fn events_arriving_between_build_and_commit_wait_for_the_next_snapshot() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x07\x1b]52;c;aGk=\x07").unwrap();
        // A first snapshot delivers the events rung before it, so only the late ones are under test.
        let first: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(first["bell"], true, "{first}");
        assert_eq!(first["clipboard"], json!(["hi"]), "{first}");
        // Build, then let the worker feed a bell and an OSC 52 while the snapshot is being serialized.
        let (value, commit) = {
            let mut model = lock_model(&session.model);
            model.build_snapshot(None, true, false).unwrap().expect("the feed made a snapshot change")
        };
        session.feed(b"\x07\x1b]52;c;b3RoZXI=\x07").unwrap();
        let sent = serde_json::to_string(&value).unwrap();
        lock_model(&session.model).commit_snapshot(commit);
        let delivered: Value = serde_json::from_str(&sent).unwrap();
        assert_eq!(delivered["bell"], false, "the snapshot carries only what its build saw: {delivered}");
        assert_eq!(delivered["clipboard"], json!([]), "{delivered}");
        // The late events survive the commit and reach the next poll exactly once.
        let next: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(next["bell"], true, "{next}");
        assert_eq!(next["clipboard"], json!(["other"]), "{next}");
        let after: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(after["bell"], false, "a delivered event is not repeated: {after}");
        assert_eq!(after["clipboard"], json!([]), "{after}");
    }

    #[test]
    fn an_abandoned_build_consumes_no_one_shot_event() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"\x07\x1b]52;c;aGk=\x07").unwrap();
        // The oversize path builds, never commits, and drops the diff base; nothing may be consumed.
        let _ = {
            let mut model = lock_model(&session.model);
            model.build_snapshot(None, true, false).unwrap().expect("the feed made a snapshot change")
        };
        lock_model(&session.model).forget_sent();
        let next: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(next["bell"], true, "{next}");
        assert_eq!(next["clipboard"], json!(["hi"]), "{next}");
    }

    #[test]
    fn a_dropped_diff_base_forces_a_full_snapshot() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.feed(b"hello").unwrap();
        let first: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        let since = first["revision"].as_u64();
        // One changed row against a held base is a partial snapshot.
        session.feed(b"x").unwrap();
        let partial: Value = serde_json::from_str(&session.snapshot(since, true, false).unwrap()).unwrap();
        assert_eq!(partial["partial"], true, "{partial}");
        // Without the base the next poll must carry every row, which is what the oversize path leaves behind.
        let revision = partial["revision"].as_u64();
        lock_model(&session.model).forget_sent();
        session.feed(b"y").unwrap();
        let full: Value = serde_json::from_str(&session.snapshot(revision, true, false).unwrap()).unwrap();
        assert_eq!(full["changed"], true, "{full}");
        assert!(full.get("partial").is_none() && full.get("dirty").is_none(), "a full snapshot has no row delta: {full}");
    }

    #[test]
    fn concurrent_snapshots_on_a_live_pty_never_lose_a_bell() {
        let session = Session::new(40, 10, Some("/bin/sh".into()), Some("/tmp".into()), false, 5000, None).unwrap();
        // Let the shell install its line editing before the first command, as the echo test does.
        std::thread::sleep(std::time::Duration::from_millis(400));
        session.input_bytes(b"\r".to_vec()).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(150));
        let stop = AtomicBool::new(false);
        let reported: usize = std::thread::scope(|scope| {
            let readers: Vec<_> = (0..2)
                .map(|_| {
                    scope.spawn(|| {
                        let mut bells = 0;
                        while !stop.load(Ordering::SeqCst) {
                            // Serializing outside the model lock is what keeps this loop from stalling the
                            // worker; a panic here would poison the session and fail the join.
                            let json = session.snapshot(None, true, false).expect("a live session snapshots");
                            let snapshot: Value = serde_json::from_str(&json).expect("snapshot is JSON");
                            if snapshot["bell"].as_bool().unwrap_or(false) { bells += 1; }
                            // Yield the model lock so the PTY worker keeps feeding between polls.
                            std::thread::sleep(std::time::Duration::from_micros(200));
                        }
                        bells
                    })
                })
                .collect();
            // Each line makes the shell ring one bell on the PTY.
            for _ in 0..8 {
                session.input_bytes(b"printf '\\a'\r".to_vec()).unwrap();
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            let deadline = Instant::now() + std::time::Duration::from_secs(10);
            while { let (rung, sent) = lock_model(&session.model).bell_counts(); rung == 0 || sent < rung } {
                assert!(Instant::now() < deadline, "the shell's bells never reached a snapshot");
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            stop.store(true, Ordering::SeqCst);
            readers.into_iter().map(|reader| reader.join().expect("no snapshot panicked")).sum()
        });
        assert!(reported > 0, "every rung bell is reported at least once");
        // A final poll sees no outstanding bell, and the counters agree that everything was delivered.
        let last: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(last["bell"], false, "{last}");
        let (rung, sent) = lock_model(&session.model).bell_counts();
        assert_eq!((rung, sent), (rung, rung), "every bell rung was delivered exactly once");
    }

    /// One compact JSON cell or one binary-block cell, normalized so the transports compare directly.
    #[derive(Debug, PartialEq)]
    struct WireCell {
        row: i32,
        col: u16,
        fg: [u8; 3],
        bg: [u8; 3],
        attrs: u16,
        ucolor: Option<[u8; 3]>,
        link: Option<u32>,
        text: String,
    }

    fn take<'a>(block: &'a [u8], at: &mut usize, len: usize) -> &'a [u8] {
        let bytes = &block[*at..*at + len];
        *at += len;
        bytes
    }

    fn decode_binary(block: &[u8], count: usize) -> Vec<WireCell> {
        let mut at = 0;
        let mut cells = Vec::with_capacity(count);
        while at < block.len() {
            let row = i32::from_le_bytes(take(block, &mut at, 4).try_into().unwrap());
            let col = u16::from_le_bytes(take(block, &mut at, 2).try_into().unwrap());
            let fg = take(block, &mut at, 3).try_into().unwrap();
            let bg = take(block, &mut at, 3).try_into().unwrap();
            let attrs = u16::from_le_bytes(take(block, &mut at, 2).try_into().unwrap());
            let presence = take(block, &mut at, 1)[0];
            let ucolor = (presence & 1 != 0).then(|| take(block, &mut at, 3).try_into().unwrap());
            let link = (presence & 2 != 0)
                .then(|| u32::from_le_bytes(take(block, &mut at, 4).try_into().unwrap()));
            let len = take(block, &mut at, 1)[0] as usize;
            let text = std::str::from_utf8(take(block, &mut at, len)).unwrap().to_string();
            cells.push(WireCell { row, col, fg, bg, attrs, ucolor, link, text });
        }
        assert_eq!(at, block.len(), "the block must end exactly after the last cell");
        assert_eq!(cells.len(), count, "cells_binary.count must match the block");
        cells
    }

    fn json_cells(json: &str) -> Vec<WireCell> {
        let value: Value = serde_json::from_str(json).unwrap();
        let rgb = |value: &Value| {
            let packed = value.as_u64().unwrap() as u32;
            [(packed >> 16) as u8, (packed >> 8) as u8, packed as u8]
        };
        value["cells"].as_array().unwrap().iter().map(|cell| {
            let cell = cell.as_array().unwrap();
            WireCell {
                row: cell[0].as_i64().unwrap() as i32,
                col: cell[1].as_u64().unwrap() as u16,
                text: cell[2].as_str().unwrap().to_string(),
                fg: rgb(&cell[3]),
                bg: rgb(&cell[4]),
                attrs: cell[5].as_u64().unwrap() as u16,
                ucolor: (cell.len() > 6 && !cell[6].is_null()).then(|| rgb(&cell[6])),
                link: (cell.len() > 7).then(|| cell[7].as_u64().unwrap() as u32),
            }
        }).collect()
    }

    /// A screen with wide/CJK, combining, links, underline colours, RGB cells, selection and a search hit.
    fn feed_showcase(session: &Session) {
        session.feed(concat!(
            "\x1b[2J\x1b[H",
            "\x1b[31mred \x1b[4m\x1b[58;2;200;10;10munder\x1b[0m ",
            "\x1b]8;;https://example.test/a\x1b\\link\x1b]8;;\x1b\\ ",
            "界 wide e\u{301}combining\r\n",
            "\x1b[38;2;10;200;30m\x1b[48;2;1;2;3mRGB\x1b[0m\r\n",
            "boring last line"
        ).as_bytes()).unwrap();
        session.select(0, 0, 0, 5).unwrap();
        session.find("link", None, false).unwrap();
    }

    fn binary_head(json: &str, block: &[u8]) -> Value {
        let head: Value = serde_json::from_str(json).unwrap();
        assert_eq!(head["cells"], json!([]), "binary snapshots must not also send JSON cells");
        assert_eq!(head["cells_binary"]["version"], 1);
        assert_eq!(head["cells_binary"]["bytes"].as_u64().unwrap() as usize, block.len());
        head
    }

    #[test]
    fn binary_cells_match_compact_json_on_full_and_partial_snapshots() {
        let json_session = Session::new(40, 8, None, None, true, 5000, None).unwrap();
        let binary_session = Session::new(40, 8, None, None, true, 5000, None).unwrap();
        for session in [&json_session, &binary_session] { feed_showcase(session); }
        let (json_full, none) = json_session.snapshot_with(None, true, true, false).unwrap();
        assert!(none.is_none());
        let (json_head, block) = binary_session.snapshot_with(None, true, true, true).unwrap();
        let block = block.expect("binary cells are honored");
        let head = binary_head(&json_head, &block);
        let count = head["cells_binary"]["count"].as_u64().unwrap() as usize;
        assert_eq!(json_cells(&json_full), decode_binary(&block, count));
        // Scroll both screens identically; the shift/dirty shape must agree as well as the cells.
        for session in [&json_session, &binary_session] {
            session.feed(b"\x1b[8;1H\r\none\r\ntwo\r\nthree").unwrap();
        }
        let json_rev = serde_json::from_str::<Value>(&json_full).unwrap()["revision"].as_u64().unwrap();
        let bin_rev = head["revision"].as_u64().unwrap();
        let (json_partial, _) = json_session.snapshot_with(Some(json_rev), true, true, false).unwrap();
        let (bin_partial, block) = binary_session.snapshot_with(Some(bin_rev), true, true, true).unwrap();
        let block = block.expect("binary cells are honored");
        let head = binary_head(&bin_partial, &block);
        let count = head["cells_binary"]["count"].as_u64().unwrap() as usize;
        assert_eq!(json_cells(&json_partial), decode_binary(&block, count));
        let value: Value = serde_json::from_str(&json_partial).unwrap();
        assert_eq!(value["partial"], true, "the scroll should ship a partial");
        assert!(value["shift"].as_u64().is_some(), "the scroll should be detected as a shift");
        assert_eq!(value["dirty"], head["dirty"]);
        assert_eq!(value["shift"], head["shift"]);
    }

    #[test]
    fn binary_cell_bytes_count_against_the_response_limit() {
        let session = Session::new(40, 8, None, None, true, 5000, None).unwrap();
        feed_showcase(&session);
        let (json, block) = session.snapshot_with_bound(None, true, true, true, usize::MAX).unwrap();
        let block = block.expect("binary cells are honored");
        // Above the JSON head but below head + NUL + block: JSON-only accounting would have accepted it.
        let bound = json.len() + block.len() / 2;
        assert!(bound > json.len() && bound < json.len() + block.len() + 1);
        let error = session.snapshot_with_bound(None, true, true, true, bound).unwrap_err();
        assert_eq!(error, "snapshot exceeds 8 MiB", "{error}");
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
        let polled: Value = serde_json::from_str(&session.snapshot(Some(since), true, false).unwrap()).unwrap();
        assert_eq!(polled["changed"], true, "the drop must not be hidden: {polled}");
        assert_eq!(polled["error"], REPLY_BACKLOG_ERROR, "{polled}");
    }

    #[test]
    fn clean_finalization_keeps_the_error_the_host_was_already_shown() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        session.model.lock().unwrap().error = Some(REPLY_BACKLOG_ERROR.into());
        // A clean shutdown has no IO failure, so it must not turn a reported error into success.
        finalize(&session.model, Some(0), None, None);
        let model = session.model.lock().unwrap();
        assert_eq!(model.error.as_deref(), Some(REPLY_BACKLOG_ERROR));
        assert!(model.exited);
        assert_eq!(model.exit_code, Some(0));
        drop(model);
        // A real IO failure still becomes the error the host reads.
        finalize(&session.model, Some(1), Some("PTY read failed"), Some("cleanup delayed"));
        assert_eq!(session.model.lock().unwrap().error.as_deref(), Some("PTY read failed"));
    }

    #[test]
    fn cleanup_failure_preserves_the_primary_error_and_is_visible_otherwise() {
        for earlier in [Some(ENGINE_FAILED), Some(REPLY_BACKLOG_ERROR), None] {
            let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
            session.model.lock().unwrap().error = earlier.map(str::to_owned);
            finalize(&session.model, None, None, Some("cleanup delayed"));
            let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
            assert_eq!(snapshot["error"], earlier.unwrap_or("cleanup delayed"));
            assert_eq!(snapshot["exited"], true);
        }
    }

    /// Stage two over a headless model, standing in for the worker while a test drives the
    /// reader side directly. `fd` is where replies to the program are written.
    fn pump_for<'a>(session: &'a Session, ring: &'a Ring, fd: i32) -> (Pump<'a>, Arc<AtomicBool>) {
        let delivered = Arc::new(AtomicBool::new(false));
        let pump = Pump {
            model: &session.model,
            ring,
            output: VecDeque::new(),
            response_pending: 0,
            pending: Arc::new(AtomicUsize::new(0)),
            delivered: delivered.clone(),
            fd,
        };
        (pump, delivered)
    }

    /// Publish one already-gathered chunk, the unit the reader hands over once a slot is filled or
    /// a read would block.
    fn publish(ring: &Ring, bytes: &[u8]) {
        let mut slot = ring.checkout().expect("the ring always has a free slot here");
        assert!(bytes.len() <= slot.len(), "a test chunk must fit one slot");
        slot[..bytes.len()].copy_from_slice(bytes);
        ring.publish(slot, bytes.len());
    }

    /// Apply every published slot in ring order, as one worker pass does.
    fn parse_all(pump: &mut Pump<'_>, ring: &Ring) {
        while let Some((slot, len)) = ring.take_ready_up_to(usize::MAX) {
            pump.feed(&slot[..len]);
            ring.recycle(slot);
        }
    }

    #[test]
    fn a_burst_of_published_slots_is_applied_once_per_pass() {
        let session = Session::new(80, 3, None, None, true, 0, None).unwrap();
        let ring = Ring::new();
        let (mut pump, _) = pump_for(&session, &ring, -1);
        let revision = lock_model(&session.model).revision;
        for _ in 0..RING_SLOTS {
            publish(&ring, b"burst\r\n");
        }
        // One pass covers the whole burst, so the worker wakes the host once for it instead of
        // once per parser chunk.
        assert!(pump.parse_pass(), "one pass applies every ready slot");
        assert!(!ring.pending(), "the burst is fully applied by that pass");
        assert!(!pump.parse_pass(), "an empty ring asks for no further notification");
        assert_eq!(
            lock_model(&session.model).revision - revision,
            RING_SLOTS as u64,
            "each slot is one model feed"
        );
        let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(snapshot["lines"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn a_partial_line_is_applied_before_the_rest_of_the_output_arrives() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let ring = Ring::new();
        let (mut pump, _) = pump_for(&session, &ring, -1);
        // A prompt with no terminator: it must be visible on the pass that read it, not held
        // back until a buffer fills or the stream ends.
        publish(&ring, b"prompt$ ");
        assert!(pump.parse_pass());
        let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(snapshot["lines"][0].as_str().unwrap().trim_end(), "prompt$");
        publish(&ring, b"x");
        assert!(pump.parse_pass());
        let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
        assert_eq!(snapshot["lines"][0].as_str().unwrap().trim_end(), "prompt$ x");
    }

    #[test]
    fn a_slot_is_handed_out_again_only_after_the_parser_returns_it() {
        let ring = Ring::new();
        let held: Vec<_> = std::iter::from_fn(|| ring.checkout()).collect();
        assert_eq!(held.len(), RING_SLOTS, "the ring allocates exactly its fixed slots");
        // Backpressure is a bounded wait, never a new allocation.
        assert!(ring.checkout().is_none());
        assert!(ring.checkout_within(Duration::from_millis(1)).is_none());
        for slot in held {
            ring.publish(slot, 1);
        }
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("the first published slot");
        assert_eq!(len, 1);
        // A slot the parser holds is still not free, so a stalled parse cannot grow the backlog.
        assert!(ring.checkout().is_none());
        ring.recycle(slot);
        assert!(ring.checkout().is_some(), "recycling a parsed slot releases the reader");
        assert!(ring.take_ready_up_to(usize::MAX).is_some(), "published slots keep their order");
    }

    #[test]
    fn an_unused_reader_slot_does_not_release_a_parsed_one() {
        let ring = Ring::new();
        publish(&ring, b"abc");
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("the published slot");
        assert_eq!(len, 3);
        assert_eq!(ring.in_flight(), 1);
        // The reader takes a free slot, finds nothing to read and hands it back while the parser
        // still holds another. That release must not count as a finished parse.
        let spare = ring.checkout().expect("a free slot");
        ring.release(spare);
        assert_eq!(ring.in_flight(), 1, "an unused reader slot is not a parsed one");
        ring.end(Ok(()));
        assert!(!ring.idle(), "output the parser still holds is not applied yet");
        ring.recycle(slot);
        assert!(ring.idle(), "the parser returned the last slot, so the ring is idle");
    }

    /// A ring whose parser holds one applied-but-unreturned slot, so the reader sees it busy.
    fn busy_bridging_ring() -> (Ring, Box<[u8]>) {
        let ring = Ring::with_idle_wake().unwrap();
        let slot = ring.checkout().unwrap();
        ring.publish(slot, 1);
        let (slot, _) = ring.take_ready_up_to(usize::MAX).unwrap();
        (ring, slot)
    }

    /// Scripted master: `Some(n)` reads n bytes, `None` would block; past the end it keeps blocking.
    fn scripted(script: Vec<Option<usize>>) -> impl FnMut(&mut [u8]) -> Result<Option<usize>, String> {
        let mut steps = script.into_iter();
        move |buffer: &mut [u8]| match steps.next().flatten() {
            Some(count) => { buffer[..count].fill(b'x'); Ok(Some(count)) }
            None => Ok(None),
        }
    }

    #[test]
    fn a_short_read_is_published_without_bridging_even_when_the_parser_is_busy() {
        let (ring, held) = busy_bridging_ring();
        let wake = Wake::new().unwrap();
        let mut bridged = 0;
        let result = fill_ring_coalescing(&ring, || false, &wake, scripted(vec![Some(100)]), || { bridged += 1; Bridge::Readable });
        assert!(matches!(result, Ok(Fill::Idle)));
        assert_eq!(bridged, 0, "interactive output below one full read is never held");
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("published at once");
        assert_eq!(len, 100);
        ring.recycle(slot);
        ring.recycle(held);
    }

    #[test]
    fn an_idle_parser_gets_a_saturated_read_without_a_bridge_wait() {
        let ring = Ring::with_idle_wake().unwrap();
        let wake = Wake::new().unwrap();
        let mut bridged = 0;
        let result = fill_ring_coalescing(&ring, || false, &wake, scripted(vec![Some(1024)]), || { bridged += 1; Bridge::Readable });
        assert!(matches!(result, Ok(Fill::Idle)));
        assert_eq!(bridged, 0, "holding bytes from an idle parser would only add latency");
        assert_eq!(ring.take_ready_up_to(usize::MAX).map(|(_, len)| len), Some(1024));
    }

    #[test]
    fn a_saturated_stream_bridges_refill_gaps_into_one_slot_while_the_parser_is_busy() {
        let (ring, held) = busy_bridging_ring();
        let wake = Wake::new().unwrap();
        // A short gap the retries cover, then a gap longer than the retries that needs one bridge wait.
        let mut script = vec![Some(1024), None, None, None, Some(1024)];
        script.extend(std::iter::repeat_n(None, BRIDGE_SPINS + 1));
        script.push(Some(1024));
        let mut bridged = 0;
        let result = fill_ring_coalescing(&ring, || false, &wake, scripted(script), || {
            bridged += 1;
            if bridged == 1 { Bridge::Readable } else { Bridge::Deliver }
        });
        assert!(matches!(result, Ok(Fill::Idle)));
        assert_eq!(bridged, 2, "one wait bridged the long gap; the final quiet wait delivered");
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("one coalesced slot");
        assert_eq!(len, 3 * 1024, "three 1 KiB reads share one slot instead of three");
        assert!(!ring.pending());
        ring.recycle(slot);
        ring.recycle(held);
    }

    #[test]
    fn the_parser_going_idle_interrupts_a_bridge_wait() {
        let (ring, held) = busy_bridging_ring();
        let wake = Wake::new().unwrap();
        let idle_fd = ring.idle_fd().unwrap();
        let mut held = Some(held);
        let mut signalled = false;
        let result = fill_ring_coalescing(&ring, || false, &wake, scripted(vec![Some(1024)]), || {
            // The parser returns its last slot during the wait: the reader must be told at once.
            ring.recycle(held.take().unwrap());
            let mut poll = libc::pollfd { fd: idle_fd, events: libc::POLLIN, revents: 0 };
            signalled = unsafe { libc::poll(&mut poll, 1, 0) } == 1;
            Bridge::Deliver
        });
        assert!(matches!(result, Ok(Fill::Idle)));
        assert!(signalled, "recycle must write the idle pipe while the reader bridges");
        let mut poll = libc::pollfd { fd: idle_fd, events: libc::POLLIN, revents: 0 };
        assert_eq!(unsafe { libc::poll(&mut poll, 1, 0) }, 0, "ending the bridge drains the idle wake");
        assert_eq!(ring.take_ready_up_to(usize::MAX).map(|(_, len)| len), Some(1024));
        // Outside a bridge the parser never writes the idle pipe.
        let slot = ring.checkout().unwrap();
        ring.publish(slot, 1);
        let (slot, _) = ring.take_ready_up_to(usize::MAX).unwrap();
        ring.recycle(slot);
        assert_eq!(unsafe { libc::poll(&mut poll, 1, 0) }, 0, "an interactive terminal pays no idle syscall");
    }

    #[test]
    fn the_bridge_budget_publishes_a_slot_that_keeps_waiting() {
        let (ring, held) = busy_bridging_ring();
        let wake = Wake::new().unwrap();
        let mut bridged = 0;
        let started = Instant::now();
        // The master never refills, yet every wait reports readable: only the budget ends the slot.
        let result = fill_ring_coalescing(&ring, || false, &wake, scripted(vec![Some(1024)]), || {
            bridged += 1;
            std::thread::sleep(Duration::from_millis(1));
            Bridge::Readable
        });
        assert!(matches!(result, Ok(Fill::Idle)));
        assert!(bridged >= 1 && started.elapsed() < Duration::from_millis(200), "bounded by the budget: {bridged}");
        assert_eq!(ring.take_ready_up_to(usize::MAX).map(|(_, len)| len), Some(1024));
        ring.recycle(held);
    }

    #[test]
    fn a_small_refill_does_not_renew_the_bridge_budget() {
        let (ring, held) = busy_bridging_ring();
        let wake = Wake::new().unwrap();
        let mut step = 0;
        let result = fill_ring_coalescing(&ring, || false, &wake, |buffer| {
            step += 1;
            match step {
                1 => { buffer[..SATURATED_BYTES].fill(b'x'); Ok(Some(SATURATED_BYTES)) }
                2 | 4 => Ok(None),
                3 => { thread::sleep(BRIDGE_BUDGET); buffer[0] = b'y'; Ok(Some(1)) }
                5 => { buffer[0] = b'z'; Ok(Some(1)) }
                _ => Ok(None),
            }
        }, || Bridge::Deliver);
        assert!(matches!(result, Ok(Fill::Idle)));
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("budget published the slot");
        assert_eq!(len, SATURATED_BYTES + 1);
        assert_eq!(slot[len - 1], b'y', "refill bytes are still delivered");
        ring.recycle(slot);
        ring.recycle(held);
    }

    #[test]
    fn a_stop_during_a_bridge_publishes_what_was_gathered() {
        let (ring, held) = busy_bridging_ring();
        let wake = Wake::new().unwrap();
        let stop = AtomicBool::new(false);
        let result = fill_ring_coalescing(&ring, || stop.load(Ordering::SeqCst), &wake, scripted(vec![Some(1024)]), || {
            stop.store(true, Ordering::SeqCst);
            Bridge::Readable
        });
        assert!(matches!(result, Ok(Fill::Idle)));
        assert_eq!(ring.take_ready_up_to(usize::MAX).map(|(_, len)| len), Some(1024), "a stop never drops gathered bytes");
        ring.recycle(held);
    }

    #[test]
    fn immediately_available_small_reads_gather_into_one_slot() {
        let ring = Ring::new();
        let wake = Wake::new().unwrap();
        let mut reads = 0;
        // Three one-byte reads are all available, then a read would block. One slot must carry all
        // three: publishing per read would waste the 64 KiB batching the ring exists for.
        let result = fill_ring(&ring, || false, &wake, |buffer| {
            if reads == 3 { return Ok(None); }
            reads += 1;
            buffer[0] = b'x';
            Ok(Some(1))
        });
        assert!(matches!(result, Ok(Fill::Idle)), "would-block ends the gather, not the slot");
        assert_eq!(ring.in_flight(), 0);
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("one gathered slot");
        assert_eq!(len, 3, "three available reads share one slot");
        ring.recycle(slot);
        assert!(!ring.pending(), "the tail was published with the slot");
    }

    #[test]
    fn a_full_slot_publishes_and_its_remainder_becomes_the_next_tail() {
        let ring = Ring::new();
        let wake = Wake::new().unwrap();
        let total = SLOT_BYTES + 6 * 1024;
        let mut produced = 0;
        let result = fill_ring(&ring, || false, &wake, |buffer| {
            if produced == total { return Ok(None); }
            let count = 1024.min(buffer.len()).min(total - produced);
            buffer[..count].fill(b'y');
            produced += count;
            Ok(Some(count))
        });
        assert!(matches!(result, Ok(Fill::Idle)));
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("the full slot");
        assert_eq!(len, SLOT_BYTES, "a full slot is published without waiting for more");
        ring.recycle(slot);
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("the remainder");
        assert_eq!(len, 6 * 1024, "bytes after a full slot become a tail of their own");
        ring.recycle(slot);
        assert!(!ring.pending());
    }

    #[test]
    fn bytes_gathered_before_a_read_failure_are_published_before_the_error() {
        let ring = Ring::new();
        let wake = Wake::new().unwrap();
        let mut reads = 0;
        let result = fill_ring(&ring, || false, &wake, |buffer| {
            if reads == 2 { return Err("test read failed".to_owned()); }
            reads += 1;
            buffer[0] = b'z';
            Ok(Some(1))
        });
        assert_eq!(result.err().as_deref(), Some("test read failed"));
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("the gathered bytes");
        assert_eq!(len, 2, "a failure must not discard the bytes already read");
        ring.recycle(slot);
    }

    #[test]
    fn a_tail_is_published_on_would_block_eof_and_failure_in_stream_order() {
        let bytes = "hello\u{4e2d}\x07\x1b[6n".as_bytes();
        for end in [Ok(None), Ok(Some(0)), Err("test read failed".to_owned())] {
            let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
            let ring = Ring::new();
            let (mut pump, _) = pump_for(&session, &ring, -1);
            let stop = AtomicBool::new(false);
            let finish = AtomicBool::new(false);
            let wake = Wake::new().unwrap();
            let mut offset = 0;
            // Each read splits UTF-8 and the query, like small PTY reads can. A full ring pauses
            // the reader exactly as one full of published slots pauses the real one.
            let result = loop {
                let result = fill_ring(&ring, || stop.load(Ordering::SeqCst) || finish.load(Ordering::SeqCst), &wake, |buffer| {
                    if offset == bytes.len() { return end.clone(); }
                    buffer[0] = bytes[offset];
                    offset += 1;
                    Ok(Some(1))
                });
                if matches!(result, Ok(Fill::Full)) {
                    parse_all(&mut pump, &ring);
                    continue;
                }
                break result;
            };
            assert_eq!(offset, bytes.len(), "every readable byte is read");
            match &end {
                Ok(Some(_)) => assert!(matches!(result, Ok(Fill::Ended))),
                Ok(None) => assert!(matches!(result, Ok(Fill::Idle))),
                _ => assert_eq!(result.err().as_deref(), Some("test read failed")),
            }
            // The tail is published with the reads that produced it, so the parser applies it
            // without waiting for the stream to end.
            assert!(ring.pending(), "a short tail is already published");
            parse_all(&mut pump, &ring);
            let snapshot: Value = serde_json::from_str(&session.snapshot(None, true, false).unwrap()).unwrap();
            assert!(snapshot["lines"][0].as_str().unwrap().starts_with("hello\u{4e2d}"));
            assert_eq!(snapshot["bell"], true);
            let queued: Vec<u8> = pump.output.iter().flat_map(|(bytes, _, _)| bytes.iter().copied()).collect();
            assert_eq!(queued, b"\x1b[1;8R", "the query is answered in stream order");
            assert_eq!(pump.response_pending, queued.len());
        }
    }

    #[test]
    fn one_pass_keeps_every_model_lock_inside_one_parse_batch() {
        let session = Session::new(80, 3, None, None, true, 0, None).unwrap();
        let ring = Ring::new();
        let (mut pump, _) = pump_for(&session, &ring, -1);
        let revision = lock_model(&session.model).revision;
        let full = vec![b'x'; SLOT_BYTES];
        for _ in 0..RING_SLOTS {
            publish(&ring, &full);
        }
        assert!(pump.parse_pass());
        // One revision per bounded parse, so no snapshot or input command waits behind a slot.
        let feeds = lock_model(&session.model).revision - revision;
        assert_eq!(feeds, (MAX_PARSE_PER_PASS / PARSE_BATCH) as u64, "each model lock covers one parse batch");
        // `MAX_PARSE_PER_PASS` is one ring, so a full ring is consumed without splitting a slot.
        assert!(!ring.pending());
    }

    #[test]
    fn post_exit_drain_queues_the_replies_the_program_asked_for() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let ring = Ring::new();
        let (mut pump, _) = pump_for(&session, &ring, -1);
        // The post-exit drain publishes into the same ring, so answers parsed after the shell
        // exits used to be dropped on the floor only because the old drain kept its own buffer.
        publish(&ring, b"\x1b[6n");
        parse_all(&mut pump, &ring);
        let queued: Vec<u8> = pump.output.iter().flat_map(|(bytes, _, _)| bytes.iter().copied()).collect();
        assert!(!queued.is_empty(), "post-exit replies must reach the PTY: {queued:?}");
        assert_eq!(queued, b"\x1b[1;1R");
        assert_eq!(pump.response_pending, queued.len(), "queued bytes must count against the backlog");
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
        let ring = Ring::new();
        let wake = Wake::new().unwrap();
        let delivered = AtomicBool::new(false);
        let failure = drain_after_exit(master, &ring, &wake, &delivered, &AtomicBool::new(false));
        ring.end(failure);
        let (mut pump, delivered) = pump_for(&session, &ring, master);
        pump.drain_until_end(true, Instant::now() + Duration::from_millis(200));
        // The answer must be written back, not merely left queued for a parser that never runs.
        let mut received = [0u8; 16];
        // SAFETY: reading into a valid buffer from a descriptor this test owns.
        let count = unsafe { libc::read(program, received.as_mut_ptr().cast(), received.len()) };
        assert!(count > 0, "the drain wrote no reply back to the terminal");
        assert_eq!(&received[..count.max(0) as usize], b"\x1b[1;1R");
        assert!(pump.output.is_empty(), "the drain must deliver what it queued: {output:?}", output = pump.output);
        assert_eq!(pump.response_pending, 0);
        assert!(delivered.load(Ordering::SeqCst), "a written reply tells the reader to wait for its reader");
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
    fn the_close_drain_continues_across_a_would_block() {
        let ring = Ring::new();
        let wake = Wake::new().unwrap();
        // Scripted evidence, no wall clock: readable -> seven bytes -> would-block, then readable
        // again -> five bytes -> would-block, then two quiet polls end the bounded drain. The old
        // drain gave up on the first would-block and dropped the second write.
        let mut probes = [Some(false), Some(false), None, None].into_iter();
        let mut reads = [
            Ok(Some(7usize)),
            Ok(None),
            Ok(Some(5usize)),
            Ok(None),
        ]
        .into_iter();
        drain_to_quiet_with(
            &ring,
            &wake,
            || probes.next().expect("the drain polls at most twice per window"),
            |buffer, _hung_up| {
                let step = reads.next().expect("the drain reads only while readable");
                if let Ok(Some(count)) = step {
                    buffer[..count].fill(b'p');
                }
                step
            },
        );
        let mut seen = 0usize;
        while let Some((slot, len)) = ring.take_ready_up_to(usize::MAX) {
            seen += len;
            ring.recycle(slot);
        }
        assert_eq!(seen, 12, "the drain kept reading after a would-block: {seen} of 12 bytes");
        assert!(!ring.pending());
        assert_eq!(ring.in_flight(), 0, "an empty read never counts as a parsed slot");
    }

    #[test]
    fn a_query_sent_just_before_eof_is_published_and_answered() {
        let (master, program) = socket_pair();
        let ring = Ring::new();
        let control = ReaderControl {
            stop: Arc::new(AtomicBool::new(false)),
            finish: Arc::new(AtomicBool::new(false)),
            abandon: Arc::new(AtomicBool::new(false)),
            wake: Arc::new(Wake::new().unwrap()),
        };
        let wake = Wake::new().unwrap();
        let delivered = AtomicBool::new(false);
        // The program asks for a cursor position report and then hangs up its write side, so the
        // reader sees data followed by EOF. EOF must run the bounded post-exit drain and the
        // answer must still reach the program.
        // SAFETY: writing into a descriptor this test owns.
        assert_eq!(unsafe { libc::write(program, b"\x1b[6n".as_ptr().cast(), 4) }, 4);
        // SAFETY: shutting down the write side of a descriptor this test owns.
        assert_eq!(unsafe { libc::shutdown(program, libc::SHUT_WR) }, 0);
        read_loop(master, &ring, &control, &wake, &delivered);
        assert!(ring.ended(), "EOF ends the reader");
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (mut pump, _) = pump_for(&session, &ring, master);
        assert!(pump.drain_until_end(true, Instant::now() + Duration::from_millis(500)), "the reader ended");
        let mut received = [0u8; 16];
        // SAFETY: reading into a valid buffer from a descriptor this test owns.
        let count = unsafe { libc::read(program, received.as_mut_ptr().cast(), received.len()) };
        assert!(count > 0, "EOF must not swallow the answer to a query sent just before it");
        assert_eq!(&received[..count as usize], b"\x1b[1;1R");
        // SAFETY: closing descriptors this test created.
        unsafe { libc::close(master); libc::close(program) };
    }

    #[test]
    fn post_exit_drain_keeps_the_second_window_after_a_quiet_poll() {
        let ring = Ring::new();
        let wake = Wake::new().unwrap();
        let delivered = AtomicBool::new(false);
        let mut reads = 0;
        let mut polls = 0;
        drain_after_exit_with(&ring, &wake, &delivered, Instant::now() + Duration::from_secs(2), || false, |buffer| {
            reads += 1;
            if reads == 2 {
                buffer[..4].copy_from_slice(b"\x1b[6n");
                Ok(Some(4))
            } else {
                Ok(None)
            }
        }, |_| {
            polls += 1;
            Ok(())
        }).unwrap();
        let (slot, len) = ring.take_ready_up_to(usize::MAX).expect("the late query was published");
        assert_eq!(&slot[..len], b"\x1b[6n");
        ring.recycle(slot);
        assert_eq!(polls, 3, "the published burst resets the two-window idle budget");
        assert_eq!(reads, 5, "the drain still ends when its idle budget is spent");
    }

    #[test]
    fn post_exit_drain_reports_poll_failure_without_leaking_a_slot() {
        let ring = Ring::new();
        let wake = Wake::new().unwrap();
        let failure = drain_after_exit_with(&ring, &wake, &AtomicBool::new(false), Instant::now() + Duration::from_secs(2), || false, |_| Ok(None),
            |_| Err("PTY drain poll failed: test failure".into()));
        assert_eq!(failure.unwrap_err(), "PTY drain poll failed: test failure");
        assert_eq!(ring.lock().free.len(), RING_SLOTS);
    }

    #[test]
    fn a_late_query_from_a_descendant_is_answered_before_the_master_closes() {
        let (master, program) = socket_pair();
        // A descendant keeps the slave open after the shell exits, which is why the master never
        // sees EOF here: only the bounded post-exit drain can catch its late query.
        // SAFETY: dup of a descriptor this test owns.
        let descendant = unsafe { libc::dup(program) };
        assert!(descendant >= 0);
        let ring = Ring::new();
        let wake = Wake::new().unwrap();
        let delivered = AtomicBool::new(false);
        let (write_tx, write_rx) = std::sync::mpsc::sync_channel(0);
        let (written_tx, written_rx) = std::sync::mpsc::sync_channel(0);
        let writer = std::thread::spawn(move || {
            write_rx.recv().unwrap();
            // SAFETY: writing a valid slice into a descriptor this test owns.
            assert_eq!(unsafe { libc::write(descendant, b"\x1b[6n".as_ptr().cast(), 4) }, 4);
            written_tx.send(()).unwrap();
        });
        let mut requested = false;
        let failure = drain_after_exit_with(&ring, &wake, &delivered, Instant::now() + Duration::from_secs(2), || false,
            |buffer| read_pty(master, buffer, true), |wait| {
                // Schedule the descendant only after the drain sees an empty read, then wait for
                // its write explicitly. A loaded CI host need not schedule it inside a 10 ms sleep.
                if !requested { write_tx.send(()).unwrap(); written_rx.recv().unwrap(); requested = true; }
                let mut poll = libc::pollfd { fd: master, events: libc::POLLIN, revents: 0 };
                // SAFETY: poll references this test's live master descriptor.
                assert!(unsafe { libc::poll(&mut poll, 1, wait) } >= 0);
                Ok(())
            });
        writer.join().unwrap();
        ring.end(failure);
        // Finalization order: apply every remaining slot, then deliver every reply, while the
        // master is still open. A flush that ran before the drain finished would drop this answer.
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (mut pump, pump_delivered) = pump_for(&session, &ring, master);
        assert!(pump.drain_until_end(true, Instant::now() + Duration::from_millis(500)));
        pump.flush();
        assert!(pump_delivered.load(Ordering::SeqCst), "the final flush wrote the answer");
        let mut received = [0u8; 16];
        // SAFETY: reading into a valid buffer from a descriptor this test owns.
        let count = unsafe { libc::read(descendant, received.as_mut_ptr().cast(), received.len()) };
        assert!(count > 0, "a late descendant query was never answered");
        assert_eq!(&received[..count as usize], b"\x1b[1;1R");
        // SAFETY: closing descriptors this test created.
        unsafe { libc::close(master); libc::close(program); libc::close(descendant) };
    }

    #[test]
    fn post_exit_drain_answers_every_burst_separated_by_an_idle_window() {
        let session = Session::new(20, 3, None, None, true, 5000, None).unwrap();
        let (master, program) = socket_pair();
        let ring = Ring::new();
        let wake = Wake::new().unwrap();
        let delivered = AtomicBool::new(false);
        // Three bursts, each written after the drain has already seen an empty read. A shared
        // idle budget spends itself on the earlier gaps and the last burst is never answered.
        let (write_tx, write_rx) = std::sync::mpsc::sync_channel(0);
        let (written_tx, written_rx) = std::sync::mpsc::sync_channel(0);
        let writer = std::thread::spawn(move || {
            for query in [b"\x1b[c".as_slice(), b"\x1b[6n", b"\x1b[c"] {
                write_rx.recv().unwrap();
                // SAFETY: writing a valid slice into a descriptor this test owns.
                assert_eq!(unsafe { libc::write(program, query.as_ptr().cast(), query.len()) }, query.len() as isize);
                written_tx.send(()).unwrap();
            }
        });
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let (mut pump, _) = pump_for(&session, &ring, master);
                pump.drain_until_end(true, Instant::now() + Duration::from_secs(2));
            });
            let mut bursts = 0;
            let failure = drain_after_exit_with(&ring, &wake, &delivered, Instant::now() + Duration::from_secs(2), || false,
                |buffer| read_pty(master, buffer, true), |wait| {
                    if bursts < 3 { write_tx.send(()).unwrap(); written_rx.recv().unwrap(); bursts += 1; }
                    let mut poll = libc::pollfd { fd: master, events: libc::POLLIN, revents: 0 };
                    // SAFETY: poll references this test's live master descriptor.
                    assert!(unsafe { libc::poll(&mut poll, 1, wait) } >= 0);
                    Ok(())
                });
            assert!(failure.is_ok(), "{failure:?}");
            ring.end(failure);
        });
        writer.join().unwrap();
        let mut received = [0u8; 64];
        // SAFETY: reading into a valid buffer from a descriptor this test owns.
        let count = unsafe { libc::read(program, received.as_mut_ptr().cast(), received.len()) };
        let answers = b"\x1b[?62;22c\x1b[1;1R\x1b[?62;22c";
        assert!(count > 0, "the drain wrote no reply back to the terminal");
        assert_eq!(&received[..count as usize], answers, "every separated burst must be answered in order");
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
