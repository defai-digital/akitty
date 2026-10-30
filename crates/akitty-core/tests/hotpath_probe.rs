use akitty_core::{akitty_buffer_free_v1, akitty_request_v1, request};
use serde_json::{Value, json};
use std::time::Instant;
fn call(v: Value) -> Value {
    let r = request(&serde_json::to_vec(&v).unwrap());
    assert_eq!(r["ok"], true, "{r}");
    r["data"].clone()
}
fn full_screen(cols: usize, rows: usize) -> String {
    let mut s = String::from("\x1b[H");
    for r in 0..rows {
        s.push_str(&format!("\x1b[{};1H\x1b[3{}m", r + 1, r % 7 + 1));
        for c in 0..cols { s.push(char::from(b'a' + ((r + c) % 26) as u8)); }
    }
    s
}
/// Hot-path timing probe: `cargo test --release --test hotpath_probe -- --ignored --nocapture`.
#[test]
#[ignore = "benchmark; run explicitly in release mode"]
fn probe() {
    let (cols, rows) = (200, 50);
    let id = call(json!({"op":"create","cols":cols,"rows":rows,"headless":true}))["id"].as_u64().unwrap();
    // Feed throughput: ~64 MiB of colored lines, 8 KiB chunks like the PTY reader.
    let mut chunk = String::new();
    while chunk.len() < 8000 { chunk.push_str("\x1b[32mhello world \x1b[0mthe quick brown fox jumps over the lazy dog 0123456789\r\n"); }
    let t = Instant::now();
    let mut bytes = 0usize;
    for _ in 0..8192 { call(json!({"op":"feed","id":id,"text":chunk})); bytes += chunk.len(); }
    let secs = t.elapsed().as_secs_f64();
    println!("FEED  {:.1} MiB/s (includes JSON request wrapping of the test harness)", bytes as f64 / 1048576.0 / secs);
    // Direct model-speed feed is measured via the snapshot-free path above; now snapshots.
    call(json!({"op":"feed","id":id,"text":full_screen(cols, rows)}));
    let n = 100;
    let t = Instant::now();
    let mut size = 0;
    let snapshot = serde_json::to_vec(&json!({"op":"snapshot","id":id})).unwrap();
    for _ in 0..n {
        // The C ABI path the app takes: one serialization, no parse.
        // SAFETY: the request slice is live for the call, and the buffer is freed once.
        let buffer = unsafe { akitty_request_v1(snapshot.as_ptr(), snapshot.len()) };
        size = buffer.len;
        unsafe { akitty_buffer_free_v1(buffer) };
    }
    let per = t.elapsed().as_secs_f64() * 1000.0 / n as f64;
    println!("SNAPSHOT full {}x{}: {:.2} ms each (build + serialize), {} bytes", cols, rows, per, size);
    // Unchanged-poll cost (the idle 30 Hz case).
    let rev = call(json!({"op":"snapshot","id":id}))["revision"].as_u64().unwrap();
    let t = Instant::now();
    for _ in 0..10000 { call(json!({"op":"snapshot","id":id,"since":rev})); }
    println!("IDLE poll: {:.1} us each", t.elapsed().as_secs_f64() * 1e6 / 10000.0);
    call(json!({"op":"close","id":id}));
}
