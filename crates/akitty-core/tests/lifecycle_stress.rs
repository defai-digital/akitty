//! Required bounded PTY lifecycle stress; increase AKITTY_STRESS_ROUNDS for a soak.
use akitty_core::request;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

struct Session(u64);
impl Session {
    fn new() -> Self {
        Self(call(json!({"op":"create","cols":80,"rows":12,"shell":"/bin/sh","cwd":"/tmp","scrollback":100}))["id"].as_u64().unwrap())
    }
    fn command(&self, op: &str, mut args: Value) -> Value {
        args["op"] = op.into(); args["id"] = self.0.into(); call(args)
    }
}
impl Drop for Session {
    fn drop(&mut self) { call(json!({"op":"close","id":self.0})); }
}
fn call(value: Value) -> Value {
    let reply = request(&serde_json::to_vec(&value).unwrap());
    assert_eq!(reply["ok"], true, "{reply}"); reply["data"].clone()
}
fn descriptors() -> usize {
    // SAFETY: F_GETFD only queries descriptor validity; it does not change ownership.
    (0..4096).filter(|fd| unsafe { libc::fcntl(*fd, libc::F_GETFD) } >= 0).count()
}
fn wait_for(mut check: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !check() {
        assert!(Instant::now() < deadline, "lifecycle condition timed out");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn concurrent_pty_resize_output_expiry_exit_and_cleanup_settle() {
    let rounds = std::env::var("AKITTY_STRESS_ROUNDS").ok().map(|v| v.parse::<usize>().unwrap()).unwrap_or(12);
    assert!((1..=1000).contains(&rounds));
    // Include first-use reaper initialization in the resource bound.
    let baseline = descriptors();
    for round in 0..rounds {
        let sessions: Vec<_> = (0..8).map(|_| Session::new()).collect();
        let mut pids = Vec::new();
        for session in &sessions {
            session.command("input", json!({"text":"stty -echo; printf '\\033[2J\\033[HPID:%s\\n' $$\r"}));
            wait_for(|| {
                let snapshot = session.command("snapshot", json!({"compact":true}));
                let pid = snapshot["lines"].as_array().unwrap().iter().filter_map(|line| line.as_str()?.trim().strip_prefix("PID:")?.parse::<i32>().ok()).next();
                if let Some(pid) = pid { pids.push(pid); true } else { false }
            });
            for step in 0..12 {
                session.command("resize", json!({"cols":60+step,"rows":12+step%4}));
                session.command("input", json!({"text":"printf 'load\\n'\r"}));
            }
            // An interrupted synchronized update must recover in the PTY worker without UI polling.
            session.command("input", json!({"text":"printf '\\033[?2026hRECOVERED\\n'; sleep 0.3; printf 'AFTER\\n'\r"}));
        }
        for session in &sessions {
            wait_for(|| session.command("snapshot", json!({"compact":true}))["lines"].as_array().unwrap().iter().any(|line| line.as_str().unwrap().contains("RECOVERED")));
        }
        // Half exit normally, half are closed during continuous output.
        for (index, session) in sessions.iter().enumerate() {
            session.command("input", json!({"text":if index%2 == 0 { "exit 0\r" } else { "while :; do printf 'busy\\n'; done\r" }}));
        }
        let started = Instant::now();
        std::thread::scope(|scope| {
            for session in &sessions {
                scope.spawn(move || {
                    let reply = request(&serde_json::to_vec(&json!({"op":"close","id":session.0})).unwrap());
                    if reply["ok"] != true {
                        // Bounded close may hand a killed child to the shared reaper.
                        // This is acceptable only if the PID and descriptors settle below.
                        assert_eq!(reply["error"], "terminal child did not exit within 1 second; cleanup continues in background", "{reply}");
                        eprintln!("round {round}: bounded close used background reaping");
                    }
                });
            }
        });
        assert!(started.elapsed() < Duration::from_secs(5), "close exceeded bound");
        drop(sessions); // Exercise idempotent close too.
        wait_for(|| pids.iter().all(|pid| {
            // SAFETY: signal zero checks only these test-owned child PIDs.
            (unsafe { libc::kill(*pid, 0) }) == -1 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        }));
        wait_for(|| descriptors() <= baseline + 2);
        eprintln!("round {round}: 8 children reaped; descriptors {} (baseline {baseline})", descriptors());
    }
}
