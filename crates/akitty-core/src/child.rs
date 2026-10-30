use portable_pty::{Child, ExitStatus};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{OnceLock, mpsc};
use std::thread;
use std::time::{Duration, Instant};

type Process = Box<dyn Child + Send + Sync>;
static CHILDREN: AtomicUsize = AtomicUsize::new(0);
static REAPER: OnceLock<Result<mpsc::SyncSender<(Process, ChildSlot)>, String>> = OnceLock::new();

/// Include deferred cleanup in the child limit, so a stalled OS reaper cannot
/// accumulate unbounded zombies, queues or threads as windows are reopened.
pub(crate) struct ChildSlot;
impl ChildSlot {
    pub(crate) fn reserve() -> Result<Self, String> {
        reaper()?;
        CHILDREN.try_update(Ordering::SeqCst, Ordering::SeqCst, |n| (n < 64).then_some(n + 1))
            .map_err(|_| "terminal child cleanup limit reached")?;
        Ok(Self)
    }
}
impl Drop for ChildSlot {
    fn drop(&mut self) { CHILDREN.fetch_sub(1, Ordering::SeqCst); }
}

fn reaper() -> Result<&'static mpsc::SyncSender<(Process, ChildSlot)>, String> {
    REAPER.get_or_init(|| {
        let (tx, rx) = mpsc::sync_channel::<(Process, ChildSlot)>(64);
        thread::Builder::new().name("akitty-reaper".into()).spawn(move || {
            let mut pending: Vec<(Process, ChildSlot)> = Vec::new();
            loop {
                let next = if pending.is_empty() { rx.recv().map_err(|_| mpsc::RecvTimeoutError::Disconnected) }
                    else { rx.recv_timeout(Duration::from_millis(25)) };
                match next {
                    Ok(child) => pending.push(child),
                    Err(mpsc::RecvTimeoutError::Timeout) => {},
                    Err(mpsc::RecvTimeoutError::Disconnected) => return,
                }
                // Never use wait(): the OS can delay reaping even after SIGKILL.
                pending.retain_mut(|(child, _)| match child.try_wait() {
                    Ok(Some(_)) => false,
                    Err(e) if e.raw_os_error() == Some(libc::ECHILD) => false,
                    _ => true,
                });
            }
        }).map_err(|e| format!("cannot start terminal child reaper: {e}"))?;
        Ok(tx)
    }).as_ref().map_err(Clone::clone)
}

/// Owns kill/reap responsibility even when parsing unwinds or worker creation fails.
pub(crate) struct ChildGuard {
    child: Option<Process>,
    slot: Option<ChildSlot>,
    fd: i32,
    reaped: bool,
    cleanup_attempted: bool,
    exit_code: Option<u32>,
}
impl ChildGuard {
    pub(crate) fn new(child: Process, fd: i32, slot: ChildSlot) -> Self {
        Self { child: Some(child), slot: Some(slot), fd, reaped: false, cleanup_attempted: false, exit_code: None }
    }
    pub(crate) fn exit_code(&self) -> Option<u32> { self.exit_code }
    pub(crate) fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
        let result = self.child.as_mut().unwrap().try_wait()?;
        if let Some(status) = &result {
            self.reaped = true;
            self.exit_code = Some(status.exit_code());
        }
        Ok(result)
    }
    fn wait_until(&mut self, deadline: Instant) -> Result<bool, String> {
        loop {
            if self.try_wait().map_err(|e| e.to_string())?.is_some() { return Ok(true); }
            if Instant::now() >= deadline { return Ok(false); }
            thread::sleep(Duration::from_millis(10));
        }
    }
    pub(crate) fn finish(&mut self) -> Result<(), String> {
        if self.reaped { return Ok(()); }
        if self.cleanup_attempted { return Err("terminal child cleanup is deferred".into()); }
        self.cleanup_attempted = true;
        if self.try_wait().map_err(|e| e.to_string())?.is_some() { return Ok(()); }
        let pid = self.child.as_ref().unwrap().process_id()
            .and_then(|p| i32::try_from(p).ok()).filter(|&p| p > 1)
            .ok_or("terminal child has no valid process id")?;
        // SAFETY: the PTY is still owned by the worker. On spawn failure its
        // master has closed; tcgetpgrp then fails without signalling a group.
        let foreground = unsafe { libc::tcgetpgrp(self.fd) };
        let own_group = unsafe { libc::getpgrp() };
        for signal in [libc::SIGHUP, libc::SIGKILL] {
            // SAFETY: the unreaped child still owns its PID. Exclude our own
            // process group, and signal the PID too in case the shell changed groups.
            unsafe {
                if foreground > 1 && foreground != own_group { libc::kill(-foreground, signal); }
                if pid != own_group { libc::kill(-pid, signal); }
                libc::kill(pid, signal);
            }
            let grace = if signal == libc::SIGHUP { 300 } else { 700 };
            if self.wait_until(Instant::now() + Duration::from_millis(grace))? { return Ok(()); }
        }
        Err("terminal child did not exit within 1 second; cleanup continues in background".into())
    }
}
impl Drop for ChildGuard {
    fn drop(&mut self) {
        if !self.cleanup_attempted { let _ = self.finish(); }
        if !self.reaped {
            // reserve() initializes this service before spawning. At most 64 slots
            // exist, so the 64-entry queue always has space for this owned slot.
            let job = (self.child.take().unwrap(), self.slot.take().unwrap());
            if let Err(error) = reaper().unwrap().try_send(job) {
                eprintln!("terminal child reaper unavailable: {error}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, atomic::AtomicBool};

    #[derive(Debug)]
    struct DelayedChild(Arc<AtomicBool>);
    impl portable_pty::ChildKiller for DelayedChild {
        fn kill(&mut self) -> std::io::Result<()> { panic!("use explicit, nonblocking signals"); }
        fn clone_killer(&self) -> Box<dyn portable_pty::ChildKiller + Send + Sync> { Box::new(Self(self.0.clone())) }
    }
    impl Child for DelayedChild {
        fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
            Ok(self.0.load(Ordering::SeqCst).then(|| ExitStatus::with_exit_code(0)))
        }
        fn wait(&mut self) -> std::io::Result<ExitStatus> { panic!("blocking wait would hang PTY shutdown"); }
        fn process_id(&self) -> Option<u32> { None }
    }
    #[test]
    fn delayed_reaping_has_a_deadline_and_retains_child_ownership() {
        let ready = Arc::new(AtomicBool::new(false));
        let mut child = ChildGuard::new(Box::new(DelayedChild(ready.clone())), -1, ChildSlot::reserve().unwrap());
        let start = Instant::now();
        assert!(!child.wait_until(start + Duration::from_millis(40)).unwrap());
        assert!(start.elapsed() < Duration::from_millis(500));
        // Drop transfers ownership without another wait, then the one shared
        // reaper releases the child once the kernel reports it is reapable.
        child.cleanup_attempted = true;
        let weak = Arc::downgrade(&ready);
        drop(child);
        assert!(weak.strong_count() > 1);
        ready.store(true, Ordering::SeqCst);
        for _ in 0..100 {
            if weak.strong_count() == 1 { return; }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("deferred child was not reaped");
    }
}
