//! Host-notification pipe: output and exit must wake the UI, and the core-owned descriptors must
//! close with the session. Its own test binary keeps the descriptor baseline free of other tests.
use akitty_core::request;
use serde_json::{json, Value};
use std::time::{Duration, Instant};

struct Session(u64);
impl Session {
    fn new() -> Self {
        Self(call(json!({"op":"create","cols":80,"rows":12,"shell":"/bin/sh","cwd":"/tmp","scrollback":100}))["id"].as_u64().unwrap())
    }
    fn command(&self, op: &str, mut args: Value) -> Value {
        args["op"] = op.into();
        args["id"] = self.0.into();
        call(args)
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        call(json!({"op":"close","id":self.0}));
    }
}
fn call(value: Value) -> Value {
    let reply = request(&serde_json::to_vec(&value).unwrap());
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"].clone()
}
fn descriptors() -> usize {
    // SAFETY: F_GETFD only queries descriptor validity; it does not change ownership.
    (0..4096)
        .filter(|fd| unsafe { libc::fcntl(*fd, libc::F_GETFD) } >= 0)
        .count()
}
fn wait_for(mut check: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !check() {
        assert!(Instant::now() < deadline, "notify condition timed out");
        std::thread::sleep(Duration::from_millis(10));
    }
}
/// Poll the read end until it has data or the bound expires.
fn wait_readable(fd: i32, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    let mut probe = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    while Instant::now() < deadline {
        probe.revents = 0;
        // SAFETY: poll references one valid pollfd for this test-owned pipe.
        if unsafe { libc::poll(&mut probe, 1, 50) } > 0 && probe.revents & libc::POLLIN != 0 {
            return true;
        }
    }
    false
}
fn drain_readable(fd: i32) {
    let mut buffer = [0u8; 128];
    loop {
        // SAFETY: buffer is writable for its length; fd is a test-only read end.
        if unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) } <= 0 {
            return;
        }
    }
}

#[test]
fn notify_pipe_reports_output_and_exit_without_leaking() {
    let baseline = descriptors();
    for _ in 0..50 {
        let session = Session::new();
        let fd = session.command("notify_fd", json!({}))["fd"]
            .as_i64()
            .expect("notify fd") as i32;
        assert!(fd >= 0, "notify_fd must return a live read end");
        drain_readable(fd);
        session.command("input", json!({"text":"printf 'NOTIFY_OK\\n'\r"}));
        assert!(
            wait_readable(fd, Duration::from_secs(2)),
            "PTY output must wake the host"
        );
        drain_readable(fd);
        session.command("input", json!({"text":"exit 0\r"}));
        assert!(
            wait_readable(fd, Duration::from_secs(2)),
            "child exit must wake the host"
        );
        drain_readable(fd);
        // Explicit close so each round releases the wake, notify and PTY descriptors.
        drop(session);
    }
    // Both pipe ends belong to the core and close with the session; allow reaper slack only.
    wait_for(|| descriptors() <= baseline + 2);
    eprintln!(
        "notify: descriptors {} (baseline {baseline})",
        descriptors()
    );
}

#[test]
fn headless_session_has_no_notify_pipe() {
    let id = call(json!({"op":"create","cols":20,"rows":4,"headless":true}))["id"]
        .as_u64()
        .unwrap();
    let reply = request(&serde_json::to_vec(&json!({"op":"notify_fd","id":id})).unwrap());
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(
        reply["error"].as_str().unwrap().contains("headless"),
        "{reply}"
    );
    let _ = request(&serde_json::to_vec(&json!({"op":"close","id":id})).unwrap());
}

#[test]
fn host_changes_wake_the_host_but_reads_do_not() {
    let session = Session::new();
    let fd = session.command("notify_fd", json!({}))["fd"].as_i64().expect("notify fd") as i32;
    // Let the shell's startup output settle, then start from a drained pipe.
    std::thread::sleep(Duration::from_millis(300));
    drain_readable(fd);
    // Reads (snapshot, shell state, audit) must not signal, or a poller would wake itself forever.
    session.command("snapshot", json!({"compact":true}));
    session.command("shell_state", json!({}));
    session.command("control_audit", json!({}));
    assert!(!wait_readable(fd, Duration::from_millis(150)), "a read woke the host");
    // An agent lease changes the pane's status without any PTY output: the host must be told.
    let lease = session.command("control_acquire", json!({"actor":"notify-test"}))["lease"].as_u64().expect("lease");
    assert!(wait_readable(fd, Duration::from_millis(500)), "a host-side lease did not wake the host");
    drain_readable(fd);
    session.command("control_release", json!({"lease":lease}));
    assert!(wait_readable(fd, Duration::from_millis(500)), "a release did not wake the host");
}
