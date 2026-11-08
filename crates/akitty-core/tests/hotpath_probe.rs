use akitty_core::{akitty_buffer_free_v1, akitty_request_v1, request};
use serde_json::{json, Value};
use std::time::Instant;

fn call(v: Value) -> Value {
    let r = request(&serde_json::to_vec(&v).unwrap());
    assert_eq!(r["ok"], true, "{r}");
    r["data"].clone()
}

/// One dense screen row: every cell is non-blank and styled, with periodic wide/CJK,
/// combining, underline-colour and OSC 8 link cells. A full snapshot then carries every
/// column, which is the worst case the native JSON transport has to move.
fn dense_row(row: usize, cols: usize) -> String {
    let mut s = format!("\x1b[{};1H", row + 1);
    let mut col = 0;
    while col < cols {
        let n = row * cols + col;
        // Reset per cell so each cell's style is exactly what follows.
        s.push_str("\x1b[0m");
        match n % 8 {
            0 => s.push_str("\x1b[31m"),
            1 => s.push_str("\x1b[32m"),
            2 => s.push_str("\x1b[33m"),
            3 => s.push_str("\x1b[34m"),
            4 => s.push_str("\x1b[38;2;10;200;30m"),
            5 => s.push_str("\x1b[4m\x1b[58;2;200;10;10m\x1b[35m"),
            6 => s.push_str("\x1b[48;2;1;2;3m\x1b[37m"),
            _ => s.push_str("\x1b[36m"),
        }
        // One-cell links to four targets, so the link table stays small and deduplicated.
        let linked = n.is_multiple_of(10);
        if linked {
            s.push_str(&format!(
                "\x1b]8;;https://example.test/{}\x1b\\",
                (n / 10) % 4
            ));
        }
        if n % 23 == 5 && col + 1 < cols {
            s.push('界');
            col += 2;
        } else if n % 37 == 11 {
            s.push_str("e\u{301}");
            col += 1;
        } else {
            s.push(char::from(b'a' + (n % 26) as u8));
            col += 1;
        }
        if linked {
            s.push_str("\x1b]8;;\x1b\\");
        }
    }
    s
}

fn feed_dense(id: u64, cols: usize, rows: usize) {
    // Rows go one request at a time so no feed exceeds the 1 MiB request cap.
    for r in 0..rows {
        call(json!({"op": "feed", "id": id, "text": dense_row(r, cols)}));
    }
}

/// A snapshot request body, optionally asking for the binary cell block.
fn snapshot_request(id: u64, since: Option<u64>, binary: bool) -> Vec<u8> {
    let mut request = json!({"op": "snapshot", "id": id, "compact": true, "allow_shift": true});
    if let Some(since) = since {
        request["since"] = json!(since);
    }
    if binary {
        request["cells"] = json!("binary");
    }
    serde_json::to_vec(&request).unwrap()
}

/// The JSON head of a reply, before the NUL separator when a binary block follows.
fn json_head(bytes: &[u8]) -> Value {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    serde_json::from_slice(&bytes[..end]).unwrap()
}

/// One C ABI snapshot call: copy the reply so the caller can inspect it.
fn call_snapshot(request: &[u8]) -> (usize, Vec<u8>) {
    // SAFETY: the request slice is live for the call, and the buffer is freed once.
    let buffer = unsafe { akitty_request_v1(request.as_ptr(), request.len()) };
    let bytes = if buffer.data.is_null() {
        Vec::new()
    } else {
        // SAFETY: the core returned a live buffer of `len` bytes.
        unsafe { std::slice::from_raw_parts(buffer.data, buffer.len).to_vec() }
    };
    let len = buffer.len;
    unsafe { akitty_buffer_free_v1(buffer) };
    (len, bytes)
}

/// Full-snapshot cost: build + serialize only, no reply copy inside the timed loop.
fn bench_full(id: u64, cols: usize, rows: usize, binary: bool, n: usize) {
    let request = snapshot_request(id, None, binary);
    let mut size = 0;
    let t = Instant::now();
    for _ in 0..n {
        // SAFETY: the request slice is live for the call, and the buffer is freed once.
        let buffer = unsafe { akitty_request_v1(request.as_ptr(), request.len()) };
        size = buffer.len;
        unsafe { akitty_buffer_free_v1(buffer) };
    }
    let per = t.elapsed().as_secs_f64() * 1000.0 / n as f64;
    let transport = if binary { "binary cells" } else { "JSON cells" };
    println!("SNAPSHOT full {cols}x{rows} {transport}: {per:.2} ms each (build + serialize), {size} bytes");
}

/// Partial cost: five dirty rows per snapshot, fed between timed calls.
fn bench_partial(id: u64, cols: usize, rows: usize, binary: bool, n: usize) {
    let mut held = json_head(&call_snapshot(&snapshot_request(id, None, binary)).1)["data"]
        ["revision"]
        .as_u64()
        .unwrap();
    let mut total = 0.0;
    let mut size = 0;
    for i in 0..n {
        // Touch five rows; each dirty row re-sends all of its (dense) cells.
        let mut feed = String::new();
        for r in 0..5.min(rows) {
            feed.push_str(&format!(
                "\x1b[{};1H\x1b[31m{}",
                r + 1,
                if (i + r) % 2 == 0 { 'x' } else { 'y' }
            ));
        }
        call(json!({"op": "feed", "id": id, "text": feed}));
        let request = snapshot_request(id, Some(held), binary);
        let t = Instant::now();
        let (len, bytes) = call_snapshot(&request);
        total += t.elapsed().as_secs_f64();
        size = len;
        held = json_head(&bytes)["data"]["revision"].as_u64().unwrap();
    }
    let per = total * 1000.0 / n as f64;
    let transport = if binary { "binary cells" } else { "JSON cells" };
    println!(
        "SNAPSHOT partial {cols}x{rows} 5 dirty rows {transport}: {per:.2} ms each, {size} bytes"
    );
}

fn bench_sizes() {
    // The core caps a screen at 32,768 cells (model::Size::validate), so 400x100
    // (40,000 cells) is rejected; 400x80 is the nearest valid dense screen.
    for &(cols, rows) in &[(200usize, 50usize), (400, 80)] {
        let id = call(json!({"op":"create","cols":cols,"rows":rows,"headless":true}))["id"]
            .as_u64()
            .unwrap();
        feed_dense(id, cols, rows);
        bench_full(id, cols, rows, false, 50);
        bench_partial(id, cols, rows, false, 50);
        // Binary first if the core honours it; older builds ignore/deny the field.
        if request(&snapshot_request(id, None, true))
            .get("ok")
            .and_then(Value::as_bool)
            == Some(true)
        {
            bench_full(id, cols, rows, true, 50);
            bench_partial(id, cols, rows, true, 50);
        }
        call(json!({"op":"close","id":id}));
    }
}

/// Hot-path timing probe: `cargo test --release --test hotpath_probe -- --ignored --nocapture`.
#[test]
#[ignore = "benchmark; run explicitly in release mode"]
fn probe() {
    let (cols, rows) = (200, 50);
    let id = call(json!({"op":"create","cols":cols,"rows":rows,"headless":true}))["id"]
        .as_u64()
        .unwrap();
    // Feed throughput: ~64 MiB of colored lines, 8 KiB chunks like the PTY reader.
    let mut chunk = String::new();
    while chunk.len() < 8000 {
        chunk.push_str(
            "\x1b[32mhello world \x1b[0mthe quick brown fox jumps over the lazy dog 0123456789\r\n",
        );
    }
    let t = Instant::now();
    let mut bytes = 0usize;
    for _ in 0..8192 {
        call(json!({"op":"feed","id":id,"text":chunk}));
        bytes += chunk.len();
    }
    let secs = t.elapsed().as_secs_f64();
    println!(
        "FEED  {:.1} MiB/s (includes JSON request wrapping of the test harness)",
        bytes as f64 / 1048576.0 / secs
    );
    // Direct model-speed feed is measured via the snapshot-free path above; now snapshots.
    call(json!({"op":"feed","id":id,"text":dense_row(0, cols)}));
    let n = 100;
    let t = Instant::now();
    let mut size = 0;
    let snapshot = snapshot_request(id, None, false);
    for _ in 0..n {
        // SAFETY: the request slice is live for the call, and the buffer is freed once.
        let buffer = unsafe { akitty_request_v1(snapshot.as_ptr(), snapshot.len()) };
        size = buffer.len;
        unsafe { akitty_buffer_free_v1(buffer) };
    }
    let per = t.elapsed().as_secs_f64() * 1000.0 / n as f64;
    println!(
        "SNAPSHOT full {}x{}: {:.2} ms each (build + serialize), {} bytes",
        cols, rows, per, size
    );
    // Unchanged-poll cost (the idle 30 Hz case).
    let rev = call(json!({"op":"snapshot","id":id,"compact":true}))["revision"]
        .as_u64()
        .unwrap();
    let t = Instant::now();
    for _ in 0..10000 {
        call(json!({"op":"snapshot","id":id,"compact":true,"since":rev}));
    }
    println!(
        "IDLE poll: {:.1} us each",
        t.elapsed().as_secs_f64() * 1e6 / 10000.0
    );
    call(json!({"op":"close","id":id}));
    bench_sizes();
}
