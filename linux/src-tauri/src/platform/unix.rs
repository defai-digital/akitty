use akitty_agent_core::child::{ChildGuard, ChildSlot};
use portable_pty::{CommandBuilder, MasterPty, PtySize};
use std::path::Path;

pub struct Pty { master: Box<dyn MasterPty + Send>, child: ChildGuard }
impl Pty {
    pub fn new(shell: &str, cwd: &Path, integration: &Path, size: PtySize) -> Result<Self, String> {
        let name = Path::new(shell).file_name().and_then(|n| n.to_str()).unwrap_or("");
        if !Path::new(shell).is_absolute() || !["bash", "zsh"].contains(&name) { return Err("experimental sessions require an absolute bash or zsh path".into()); }
        if !cwd.is_absolute() || !cwd.is_dir() || !integration.is_absolute() { return Err("invalid session directories".into()); }
        let resource = integration.join(if name == "bash" { "bashrc" } else { ".zshenv" });
        if !resource.is_file() { return Err("bundled shell integration is missing".into()); }
        let slot = ChildSlot::reserve()?;
        let pair = portable_pty::native_pty_system().openpty(size).map_err(|e| e.to_string())?;
        let fd = pair.master.as_raw_fd().ok_or("PTY has no descriptor")?;
        // SAFETY: the master owns fd for this session's lifetime.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        // SAFETY: F_SETFL changes only flags on the owned descriptor.
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 { return Err(std::io::Error::last_os_error().to_string()); }
        let mut cmd = CommandBuilder::new(shell);
        cmd.cwd(cwd);
        cmd.env("TERM", "xterm-256color"); cmd.env("COLORTERM", "truecolor");
        cmd.env("TERM_PROGRAM", "Akitty"); cmd.env("TERM_PROGRAM_VERSION", "0.1.0-experimental");
        cmd.env("AKITTY_INTEGRATION_DIR", integration);
        if name == "bash" { cmd.args(["--rcfile", &resource.to_string_lossy(), "-i"]); }
        else {
            cmd.env("AKITTY_USER_ZDOTDIR", std::env::var("ZDOTDIR").or_else(|_| std::env::var("HOME")).unwrap_or_else(|_| "/".into()));
            cmd.env("ZDOTDIR", integration); cmd.args(["-l", "-i"]);
        }
        let child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
        drop(pair.slave);
        Ok(Self { master: pair.master, child: ChildGuard::new(child, fd, slot) })
    }
    pub fn resize(&self, size: PtySize) -> Result<(), String> { self.master.resize(size).map_err(|e| e.to_string()) }
    pub fn close(&mut self) -> Result<(), String> { self.child.finish() }
    pub fn exit_code(&self) -> Option<u32> { self.child.exit_code() }
    pub fn poll_exit(&mut self) -> Result<(), String> { self.child.try_wait().map(|_| ()).map_err(|e| e.to_string()) }
    pub fn write(&mut self, bytes: &[u8]) -> Result<usize, String> {
        let fd = self.master.as_raw_fd().ok_or("PTY descriptor closed")?;
        // SAFETY: bytes is readable and fd remains owned by master.
        let count = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if count >= 0 { Ok(count as usize) } else if retryable() { Ok(0) } else { Err(std::io::Error::last_os_error().to_string()) }
    }
    pub fn read(&mut self, bytes: &mut [u8]) -> Result<Option<usize>, String> {
        let fd = self.master.as_raw_fd().ok_or("PTY descriptor closed")?;
        // SAFETY: bytes is writable and fd remains owned by master.
        let count = unsafe { libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len()) };
        if count >= 0 { return Ok(Some(count as usize)); }
        if retryable() { return Ok(None); }
        let error = std::io::Error::last_os_error();
        let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        // SAFETY: poll points to one initialized descriptor record.
        let hangup = unsafe { libc::poll(&mut poll, 1, 0) } >= 0 && poll.revents & libc::POLLHUP != 0;
        if error.raw_os_error() == Some(libc::EIO) && hangup { Ok(Some(0)) } else { Err(error.to_string()) }
    }
    pub fn input_pending(&self) -> bool { false }
}
fn retryable() -> bool { matches!(std::io::Error::last_os_error().kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) }
