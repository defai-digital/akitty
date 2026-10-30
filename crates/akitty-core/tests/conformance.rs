use akitty_core::request;
use serde_json::{Value, json};
use std::time::{Duration, Instant};
fn call(value: Value) -> Value {
    let response = request(&serde_json::to_vec(&value).unwrap());
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}
struct Terminal(u64);
impl Terminal {
    fn new(cols: usize, rows: usize) -> Self {
        Self(
            call(json!({"op":"create","cols":cols,"rows":rows,"headless":true}))["id"]
                .as_u64()
                .unwrap(),
        )
    }
    fn feed(&self, text: &str) {
        call(json!({"op":"feed","id":self.0,"text":text}));
    }
    fn snapshot(&self) -> Value {
        call(json!({"op":"snapshot","id":self.0}))
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        call(json!({"op":"close","id":self.0}));
    }
}
#[test]
fn cursor_erase_and_truecolor() {
    let t = Terminal::new(20, 4);
    t.feed("abcdef\x1b[1;3H\x1b[K\x1b[38;2;1;2;3mZ");
    let s = t.snapshot();
    assert_eq!(s["lines"][0], "abZ                 ");
    assert_eq!(s["cells"][2]["fg"], json!([1, 2, 3]));
    assert_eq!(s["cursor"]["col"], 3);
}
#[test]
fn alternate_screen_restores_main() {
    let t = Terminal::new(12, 3);
    t.feed("main\x1b[?1049halt");
    assert_eq!(t.snapshot()["alternate"], true);
    t.feed("\x1b[?1049l");
    let s = t.snapshot();
    assert_eq!(s["alternate"], false);
    assert!(s["lines"][0].as_str().unwrap().starts_with("main"));
}
#[test]
fn wide_and_combining_cells_keep_column_authority() {
    let t = Terminal::new(20, 3);
    t.feed("中e\u{301}😀");
    let s = t.snapshot();
    assert_eq!(s["cells"][0]["wide"], true);
    assert_eq!(s["cells"][1]["text"], "");
    assert_eq!(s["cells"][2]["text"], "e\u{301}");
    assert_eq!(s["cursor"]["col"], 5);
}
#[test]
fn scrolling_and_resize_preserve_content() {
    let t = Terminal::new(12, 3);
    t.feed("one\r\ntwo\r\nthree\r\nfour");
    assert!(t.snapshot()["history"].as_u64().unwrap() > 0);
    call(json!({"op":"scroll","id":t.0,"lines":2}));
    assert!(
        t.snapshot()["lines"][0]
            .as_str()
            .unwrap()
            .starts_with("one")
    );
    call(json!({"op":"resize","id":t.0,"cols":20,"rows":5}));
    assert_eq!(t.snapshot()["cols"], 20);
}
#[test]
fn clipboard_is_bounded_text_event_not_host_write() {
    let t = Terminal::new(20, 3);
    t.feed("\x1b]52;c;aGVsbG8=\x07");
    assert_eq!(t.snapshot()["clipboard"], json!(["hello"]));
    assert_eq!(t.snapshot()["clipboard"], json!([]));
}
#[test]
fn malformed_sequences_and_unknown_osc_recover() {
    let t = Terminal::new(20, 3);
    t.feed("\x1b]999;unsupported\x07\x1b[0mok");
    assert!(t.snapshot()["lines"][0].as_str().unwrap().starts_with("ok"));
}
#[test]
fn stale_handles_and_invalid_dimensions_fail_closed() {
    let t = Terminal::new(10, 2);
    call(json!({"op":"close","id":t.0}));
    assert_eq!(
        request(&serde_json::to_vec(&json!({"op":"snapshot","id":t.0})).unwrap())["ok"],
        false
    );
    for (cols, rows) in [(0, 1), (1, 1), (513, 2), (512, 256)] {
        assert_eq!(
            request(
                &serde_json::to_vec(
                    &json!({"op":"create","cols":cols,"rows":rows,"headless":true})
                )
                .unwrap()
            )["ok"],
            false
        );
    }
}
#[test]
fn unchanged_generation_returns_no_frame() {
    let t = Terminal::new(10, 2);
    let s = t.snapshot();
    assert_eq!(
        call(json!({"op":"snapshot","id":t.0,"since":s["revision"]})),
        json!({"changed":false})
    );
}
#[test]
fn selection_and_find() {
    let t = Terminal::new(20, 3);
    t.feed("hello world");
    assert_eq!(
        call(json!({"op":"select","id":t.0,"start_row":0,"start_col":0,"end_row":0,"end_col":4}))["text"],
        "hello"
    );
    assert_eq!(
        call(json!({"op":"find","id":t.0,"text":"world"}))["found"],
        true
    );
    assert_eq!(
        call(json!({"op":"find","id":t.0,"text":"absent"}))["found"],
        false
    );
}
#[test]
fn actual_pty_roundtrip_resize_and_bounded_shutdown() {
    let id = call(json!({"op":"create","cols":40,"rows":8,"shell":"/bin/sh","cwd":"/tmp"}))["id"]
        .as_u64()
        .unwrap();
    let t = Terminal(id);
    call(
        json!({"op":"input","id":id,"text":"printf '\\101\\113\\111\\124\\124\\131\\137\\117\\113\\n'\r"}),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let s = t.snapshot();
        if s["lines"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v.as_str().unwrap().contains("AKITTY_OK"))
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "PTY did not produce expected command output: {s}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    call(json!({"op":"resize","id":id,"cols":60,"rows":12}));
    call(
        json!({"op":"input","id":id,"text":"trap '' HUP; printf '\\122\\105\\101\\104\\131\\n'\r"}),
    );
    std::thread::sleep(Duration::from_millis(100));
    let start = Instant::now();
    call(json!({"op":"close","id":id}));
    assert!(start.elapsed() < Duration::from_secs(2));
}
#[test]
fn ffi_validates_buffers_and_schema() {
    use akitty_core::{akitty_abi_version, akitty_buffer_free_v1, akitty_request_v1};
    assert_eq!(akitty_abi_version(), 1);
    unsafe {
        let buffer = akitty_request_v1(std::ptr::null(), 0);
        let value: Value =
            serde_json::from_slice(std::slice::from_raw_parts(buffer.data, buffer.len)).unwrap();
        assert_eq!(value["ok"], false);
        akitty_buffer_free_v1(buffer);
        let input = br#"{"op":"version"}"#;
        let buffer = akitty_request_v1(input.as_ptr(), input.len());
        let value: Value =
            serde_json::from_slice(std::slice::from_raw_parts(buffer.data, buffer.len)).unwrap();
        assert_eq!(value["data"]["abi"], 1);
        akitty_buffer_free_v1(buffer);
    }
    assert_eq!(request(br#"{"op":"version","unknown":true}"#)["ok"], false);
    assert_eq!(request(&[0xff])["ok"], false);
}

#[test]
fn configured_scrollback_is_enforced_and_invalid_limit_rejected() {
    let id = call(json!({"op":"create","cols":10,"rows":2,"headless":true,"scrollback":3}))["id"].as_u64().unwrap();
    let t = Terminal(id);
    t.feed(&"line\r\n".repeat(30));
    assert!(t.snapshot()["history"].as_u64().unwrap() <= 3);
    assert_eq!(request(&serde_json::to_vec(&json!({"op":"create","cols":10,"rows":2,"headless":true,"scrollback":20001})).unwrap())["ok"], false);
}

#[test]
fn normal_shell_exit_preserves_success_status_for_native_pane_cleanup() {
    let id = call(json!({"op":"create","cols":30,"rows":3,"shell":"/bin/sh","cwd":"/tmp"}))["id"].as_u64().unwrap();
    let t = Terminal(id);
    call(json!({"op":"input","id":id,"text":"exit 0\r"}));
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let snapshot = t.snapshot();
        if snapshot["exited"] == true && snapshot["exit_code"] == 0 { break; }
        assert!(Instant::now() < deadline, "exit status not propagated: {snapshot}");
        std::thread::sleep(Duration::from_millis(20));
    }
}
#[test]
fn events_are_not_dropped_within_one_large_chunk() {
    let t = Terminal::new(20, 4);
    let titles: String = (0..200).map(|i| format!("\x1b]0;t{i:03}\x07")).collect();
    t.feed(&titles);
    assert_eq!(t.snapshot()["title"], "t199");
}
#[test]
fn rejected_input_does_not_move_the_viewport() {
    let t = Terminal::new(10, 3);
    t.feed(&"line\r\n".repeat(20));
    call(json!({"op":"scroll","id":t.0,"lines":5}));
    let before = t.snapshot();
    let response = request(&serde_json::to_vec(&json!({"op":"input","id":t.0,"text":"x"})).unwrap());
    assert_eq!(response["ok"], false);
    let after = t.snapshot();
    assert_eq!(before["offset"], after["offset"]);
    assert!(after["offset"].as_u64().unwrap() > 0);
}
#[test]
fn ax_code_style_kitty_graphics_frames_are_placed_and_readable() {
    use base64::Engine;
    let t = Terminal::new(40, 10);
    call(json!({"op":"cell_size","id":t.0,"width":8,"height":16}));
    t.feed("hi\x1b[3;5H");
    let (w, h) = (64usize, 32usize);
    let raw: Vec<u8> = (0..w * h * 3).map(|i| (i % 253) as u8).collect();
    let packed = base64::engine::general_purpose::STANDARD
        .encode(miniz_oxide::deflate::compress_to_vec_zlib(&raw, 1));
    for frame in 0..3 {
        let mut sequence = String::from("\x1b7\x1b[H");
        let chunks: Vec<&str> = packed.as_bytes().chunks(4096).map(|c| std::str::from_utf8(c).unwrap()).collect();
        for (index, chunk) in chunks.iter().enumerate() {
            let more = u8::from(index + 1 < chunks.len());
            let header = if index == 0 {
                format!("a=T,f=24,o=z,s={w},v={h},i=7,p=1,c=8,r=2,C=1,z=1,q=2,")
            } else {
                String::new()
            };
            sequence.push_str(&format!("\x1b_G{header}m={more};{chunk}\x1b\\"));
        }
        sequence.push_str("\x1b8");
        t.feed(&sequence);
        let s = t.snapshot();
        let images = s["images"].as_array().unwrap();
        assert_eq!(images.len(), 1, "frame {frame}: placements must not accumulate");
        assert_eq!(images[0]["id"], 7);
        assert_eq!((images[0]["row"].as_i64(), images[0]["col"].as_i64()), (Some(0), Some(0)));
        assert_eq!((images[0]["cols"].as_u64(), images[0]["rows"].as_u64(), images[0]["z"].as_i64()), (Some(8), Some(2), Some(1)));
        assert_eq!(s["cursor"]["row"], 2, "ESC 8 and C=1 leave the cursor alone");
        assert_eq!(s["cursor"]["col"], 4);
    }
    let mut out = vec![0u8; w * h * 4];
    let copied = unsafe { akitty_core::akitty_image_read_v1(t.0, 7, out.as_mut_ptr(), out.len()) };
    assert_eq!(copied, w * h * 4);
    assert_eq!(&out[..8], &[raw[0], raw[1], raw[2], 255, raw[3], raw[4], raw[5], 255]);
    // Too-small buffers, unknown images and unknown sessions copy nothing.
    assert_eq!(unsafe { akitty_core::akitty_image_read_v1(t.0, 7, out.as_mut_ptr(), 16) }, 0);
    assert_eq!(unsafe { akitty_core::akitty_image_read_v1(t.0, 99, out.as_mut_ptr(), out.len()) }, 0);
    assert_eq!(unsafe { akitty_core::akitty_image_read_v1(u64::MAX, 7, out.as_mut_ptr(), out.len()) }, 0);
    t.feed("\x1b_Ga=d,d=I,i=7,q=2\x1b\\");
    assert_eq!(t.snapshot()["images"].as_array().unwrap().len(), 0);
}
#[test]
fn fully_decorated_maximum_grid_stays_inside_the_response_cap() {
    let t = Terminal::new(512, 64);
    let uri = "https://example.com/a/fairly/long/path/to/make/the/link/table/entry/realistic?query=1";
    t.feed(&format!("\x1b[4:3;58;2;1;2;3;9;1;3m\x1b]8;;{uri}\x07{}", "x".repeat(512 * 64)));
    let request = serde_json::to_vec(&json!({"op":"snapshot","id":t.0})).unwrap();
    let buffer = unsafe { akitty_core::akitty_request_v1(request.as_ptr(), request.len()) };
    assert!(!buffer.data.is_null());
    let bytes = unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) }.to_vec();
    unsafe { akitty_core::akitty_buffer_free_v1(buffer) };
    let response: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(response["ok"], true, "{}", String::from_utf8_lossy(&bytes[..bytes.len().min(200)]));
    assert!(bytes.len() < 8 * 1024 * 1024);
    eprintln!("worst-case snapshot: {} bytes", bytes.len());
}
#[test]
fn graphics_without_c1_moves_cursor_below_the_image() {
    use base64::Engine;
    let t = Terminal::new(40, 10);
    call(json!({"op":"cell_size","id":t.0,"width":8,"height":16}));
    let pixel = base64::engine::general_purpose::STANDARD.encode([1u8, 2, 3]);
    t.feed(&format!("ab\x1b_Ga=T,f=24,s=1,v=1,c=3,r=2,q=2;{pixel}\x1b\\"));
    let s = t.snapshot();
    assert_eq!((s["cursor"]["row"].as_i64(), s["cursor"]["col"].as_i64()), (Some(1), Some(5)));
    assert_eq!(s["images"][0]["col"], 2);
}

/// A 2x2 RGB frame (base64 of 12 zero bytes) placed without moving the cursor.
const PIXEL: &str = "AAAAAAAAAAAAAAAA";
fn frame(id: u32) -> String {
    format!("\x1b_Ga=T,f=24,s=2,v=2,i={id},q=2,C=1;{PIXEL}\x1b\\")
}

#[test]
fn images_follow_scrolls_and_leave_with_a_tiny_scrollback() {
    let id = call(json!({"op":"create","cols":12,"rows":3,"headless":true,"scrollback":2}))["id"]
        .as_u64()
        .unwrap();
    let t = Terminal(id);
    call(json!({"op":"cell_size","id":id,"width":8,"height":16}));
    t.feed("line\r\n");
    t.feed(&frame(1));
    t.feed("more\r\n");
    // The cursor is on the bottom row now; one more linefeed scrolls both
    // the text and the placement up into the two-line scrollback.
    t.feed("\r\n");
    call(json!({"op":"scroll","id":id,"lines":1}));
    let s = t.snapshot();
    let images = s["images"].as_array().unwrap();
    assert_eq!(
        images.len(),
        1,
        "the placement follows its text into scrollback"
    );
    assert_eq!(
        images[0]["row"], 1,
        "the image sits on the line it was printed on"
    );
    assert!(s["lines"][1].as_str().unwrap().starts_with("more"));
    // Once the text has left the scrollback the placement is gone for good.
    t.feed(&"tail\r\n".repeat(10));
    call(json!({"op":"scroll","id":id,"lines":5}));
    assert_eq!(t.snapshot()["images"].as_array().unwrap().len(), 0);
    assert_eq!(t.snapshot()["history"], 2);
}

#[test]
fn region_scrolls_move_only_the_placements_inside_the_region() {
    let t = Terminal::new(20, 10);
    call(json!({"op":"cell_size","id":t.0,"width":8,"height":16}));
    // Region lines [1, 5); the first image sits inside it (not on the border,
    // because content scrolled out of the region is discarded), the second outside.
    t.feed("\x1b[2;5r\x1b[3;1H");
    t.feed(&frame(1));
    t.feed("\x1b[9;1H");
    t.feed(&frame(2));
    t.feed("\x1b[5;1H\n");
    let s = t.snapshot();
    let row = |id: u64| {
        s["images"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["id"] == id)
            .unwrap()["row"]
            .as_i64()
            .unwrap()
    };
    assert_eq!((row(1), row(2)), (1, 8), "only the region placement moves");
    // Erasing the visible screen drops both; the text is gone with them.
    t.feed("\x1b[2J");
    assert_eq!(t.snapshot()["images"].as_array().unwrap().len(), 0);
}

#[test]
fn snapshot_reports_placement_rectangle_and_pixel_offsets() {
    use base64::Engine;
    let t = Terminal::new(40, 10);
    call(json!({"op":"cell_size","id":t.0,"width":8,"height":16}));
    let raw: Vec<u8> = (0..16 * 16 * 3).map(|i| (i % 251) as u8).collect();
    let packed = base64::engine::general_purpose::STANDARD.encode(raw);
    t.feed(&format!(
        "ab\x1b_Ga=T,f=24,s=16,v=16,i=9,x=4,y=6,w=8,h=4,X=3,Y=5,c=4,r=2,q=2,C=1;{packed}\x1b\\"
    ));
    let image = &t.snapshot()["images"][0];
    assert_eq!(image["sx"], 4);
    assert_eq!(image["sy"], 6);
    assert_eq!(image["sw"], 8);
    assert_eq!(image["sh"], 4);
    assert_eq!(image["ox"], 3);
    assert_eq!(image["oy"], 5);
    assert_eq!(image["cols"], 4);
    assert_eq!(image["rows"], 2);
    assert_eq!(image["row"], 0);
    assert_eq!(image["col"], 2);
}

#[test]
fn snapshots_report_every_visible_placement_without_the_old_64_cap() {
    let id = call(json!({"op":"create","cols":30,"rows":100,"headless":true}))["id"]
        .as_u64()
        .unwrap();
    let t = Terminal(id);
    call(json!({"op":"cell_size","id":id,"width":8,"height":16}));
    for row in 1..=80u32 {
        t.feed(&format!("\x1b[{row};1H"));
        t.feed(&frame(row));
    }
    assert_eq!(t.snapshot()["images"].as_array().unwrap().len(), 80);
    t.feed("\x1b[2J");
    assert_eq!(t.snapshot()["images"].as_array().unwrap().len(), 0);
}
