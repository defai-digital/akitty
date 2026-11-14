//! Opt-in measurement of the product's PTY worker, parser and model, excluding rendering.
use akitty_core::request;
use serde_json::{Value, json};
use std::path::Path;
use std::time::{Duration, Instant};

struct Session(u64);
impl Session {
    fn new() -> Self {
        let response = request(&serde_json::to_vec(&json!({
            "op": "create", "cols": 120, "rows": 40, "scrollback": 0, "shell": "/bin/sh",
        })).unwrap());
        assert_eq!(response["ok"], true, "{response}");
        Self(response["data"]["id"].as_u64().unwrap())
    }
    fn call(&self, op: &str, mut fields: Value) -> Value {
        fields["op"] = json!(op); fields["id"] = json!(self.0);
        let response = request(&serde_json::to_vec(&fields).unwrap());
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    }
    fn wait_title(&self, title: &str) {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let state = self.call("shell_state", json!({}));
            if state["title"] == title { return; }
            assert_ne!(state["exited"], true, "shell exited: {state}");
            assert!(Instant::now() < deadline, "waiting for {title}: {state}");
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}
impl Drop for Session {
    fn drop(&mut self) { self.call("close", json!({})); }
}

fn measure(path: &Path, label: &str, pattern: &str) {
    let mut payload = pattern.repeat((8 * 1024 * 1024) / pattern.len());
    payload.push_str("\x1b[0m\r\nPTY_PAYLOAD_END\r\n");
    std::fs::write(path, &payload).unwrap();
    let session = Session::new();
    // Disable echo and output newline translation; no startup or setup is timed.
    session.call("input", json!({"text": "stty -echo -onlcr; PS1=; printf '\\033]2;ready\\007'\n"}));
    session.wait_title("ready");
    let mut samples = Vec::new();
    for sample in 0..14 {
        let title = format!("finished-{sample}");
        // POSIX shell quoting also handles a checkout or temporary directory with spaces.
        let quoted = format!("'{}'", path.to_str().unwrap().replace('\'', "'\\''"));
        let command = format!("cat {quoted}; printf '\\033]2;{title}\\007'\n");
        let start = Instant::now();
        session.call("input", json!({"text": command}));
        session.wait_title(&title);
        let elapsed = start.elapsed().as_nanos();
        if sample >= 3 { samples.push(elapsed); }
        let snapshot = session.call("snapshot", json!({"compact": true}));
        assert_eq!(snapshot["error"], Value::Null, "{snapshot}");
        assert!(snapshot["lines"].as_array().unwrap().iter().any(|line| line.as_str().unwrap().contains("PTY_PAYLOAD_END")));
    }
    samples.sort_unstable();
    let p50 = samples[samples.len() / 2] as f64 / 1e9;
    println!("PTY {label}: {:.2} MiB/s; bytes={}; p50_ms={:.3}; sorted_samples_ns={samples:?}",
             payload.len() as f64 / 1048576.0 / p50, payload.len(), p50 * 1000.0);
}

/// `cargo test --release --locked -p akitty-core --test pty_throughput -- --ignored --nocapture`.
#[test]
#[ignore = "benchmark; run explicitly in release mode"]
fn pty_throughput() {
    if cfg!(debug_assertions) { panic!("run this benchmark in release mode"); }
    let directory = std::env::temp_dir().join(format!("akitty-pty-throughput-{}", std::process::id()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("payload.txt");
    measure(&path, "ascii", "the quick brown fox jumps over the lazy dog 0123456789\r\n");
    measure(&path, "ansi", "\x1b[38;2;23;175;92mcolored output\x1b[0m regular output 0123456789\r\n");
    measure(&path, "unicode", "漢字かな한글 👩‍💻 e\u{301} terminal output\r\n");
    std::fs::remove_file(path).unwrap();
    std::fs::remove_dir(directory).unwrap();
}
