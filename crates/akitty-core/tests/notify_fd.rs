//! Host-notification pipe: output and exit must wake the UI, and the core-owned descriptors must
//! close with the session. Its own test binary keeps the descriptor baseline free of other tests.
use akitty_core::request;
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The descriptor count is process-wide, so PTY tests in this binary run one at a time.
static SERIAL: Mutex<()> = Mutex::new(());
fn serial() -> std::sync::MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

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
        let reply = request(&serde_json::to_vec(&json!({"op":"close","id":self.0})).unwrap());
        // A slow runner may hand a child that has not exited yet to the shared reaper (the bounded close,
        // as in lifecycle_stress); its descriptors are released in the background, which the leak check waits for.
        if reply["ok"] != true {
            assert_eq!(reply["error"], "terminal child did not exit within 1 second; cleanup continues in background", "{reply}");
        }
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
    let _serial = serial();
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
    let _serial = serial();
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

#[test]
fn an_expiring_chrome_status_wakes_the_host_on_time() {
    let _serial = serial();
    let session = Session::new();
    let fd = session.command("notify_fd", json!({}))["fd"].as_i64().expect("notify fd") as i32;
    std::thread::sleep(Duration::from_millis(300));
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    session.command("chrome", json!({"status":{"text":"Saved","tone":"info","expires":now + 400}}));
    let shown = session.command("snapshot", json!({"compact":true}));
    assert_eq!(shown["chrome"]["status"]["text"], "Saved", "{shown}");
    // Setting chrome wakes the host once; the expiry must wake it again with no output at all.
    drain_readable(fd);
    let started = std::time::Instant::now();
    assert!(wait_readable(fd, Duration::from_millis(900)), "an expired status did not wake the host");
    let waited = started.elapsed();
    // Well before the host's 1 s safety tick, and not before the status actually expired.
    assert!(waited >= Duration::from_millis(250) && waited < Duration::from_millis(800), "woke after {waited:?}");
    let cleared = session.command("snapshot", json!({"compact":true}));
    assert!(cleared["chrome"].get("status").is_none(), "{cleared}");
}

#[test]
fn a_status_set_and_expired_within_one_idle_poll_still_wakes_the_host() {
    let _serial = serial();
    let session = Session::new();
    let fd = session.command("notify_fd", json!({}))["fd"].as_i64().expect("notify fd") as i32;
    std::thread::sleep(Duration::from_millis(300));
    // Shorter than the worker's 250 ms idle poll: setting it must wake the worker to time it.
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    session.command("chrome", json!({"status":{"text":"Brief","tone":"info","expires":now + 120}}));
    session.command("snapshot", json!({"compact":true}));
    drain_readable(fd);
    let started = std::time::Instant::now();
    assert!(wait_readable(fd, Duration::from_millis(900)), "a brief status did not wake the host");
    assert!(started.elapsed() < Duration::from_millis(240), "woke after {:?}", started.elapsed());
}

#[test]
fn a_far_future_expiry_never_fails_the_engine() {
    let _serial = serial();
    let session = Session::new();
    session.command("chrome", json!({"status":{"text":"Forever","tone":"info","expires":u64::MAX}}));
    session.command("input", json!({"text":"printf 'STILL_ALIVE\\n'\r"}));
    wait_for(|| session.command("snapshot", json!({"compact":true}))["lines"].to_string().contains("STILL_ALIVE"));
    let snapshot = session.command("snapshot", json!({"compact":true}));
    assert!(snapshot["error"].is_null(), "{snapshot}");
    assert_eq!(snapshot["chrome"]["status"]["text"], "Forever", "{snapshot}");
}

#[test]
fn an_exited_pane_still_clears_a_timed_status_on_time() {
    let _serial = serial();
    let session = Session::new();
    let fd = session.command("notify_fd", json!({}))["fd"].as_i64().expect("notify fd") as i32;
    session.command("input", json!({"text":"exit\r"}));
    wait_for(|| session.command("snapshot", json!({"compact":true}))["exited"] == true);
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    session.command("chrome", json!({"status":{"text":"Done","tone":"info","expires":now + 300}}));
    session.command("snapshot", json!({"compact":true}));
    drain_readable(fd);
    let started = std::time::Instant::now();
    assert!(wait_readable(fd, Duration::from_millis(900)), "an exited pane's status did not wake the host");
    let waited = started.elapsed();
    assert!(waited >= Duration::from_millis(150) && waited < Duration::from_millis(700), "woke after {waited:?}");
    assert!(session.command("snapshot", json!({"compact":true}))["chrome"].get("status").is_none());
    // Input to the exited pane still fails at send.
    let reply = request(&serde_json::to_vec(&json!({"op":"input","id":session.0,"text":"x"})).unwrap());
    assert_eq!(reply["ok"], false, "{reply}");
}
