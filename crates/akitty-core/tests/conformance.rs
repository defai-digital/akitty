use akitty_core::request;
use base64::Engine;
use serde_json::{Value, json};
use std::time::{Duration, Instant};
fn call(value: Value) -> Value {
    let response = request(&serde_json::to_vec(&value).unwrap());
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}
fn response(value: Value) -> Value {
    request(&serde_json::to_vec(&value).unwrap())
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
        call(json!({"op":"snapshot","id":self.0,"compact":true}))
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        call(json!({"op":"close","id":self.0}));
    }
}
#[test]
fn schema_one_snapshots_keep_keyed_cells_unless_compact_is_requested() {
    let t = Terminal::new(20, 4);
    t.feed("\x1b[1;3;4:3;9;38;2;1;2;3;58;2;4;5;6mA\x1b[0m");
    let old = call(json!({"op":"snapshot","id":t.0}));
    let cell = &old["cells"][0];
    assert!(cell.is_object(), "schema 1 defaults to the published keyed cell shape");
    assert_eq!(cell["text"], "A");
    assert_eq!(cell["fg"], json!([1, 2, 3]));
    assert_eq!(cell["ucolor"], json!([4, 5, 6]));
    assert_eq!(cell["ustyle"], 3);
    for flag in ["bold", "italic", "underline", "strike"] { assert_eq!(cell[flag], true); }
    assert_eq!(old["links"], json!([]));
    let compact = call(json!({"op":"snapshot","id":t.0,"compact":true}));
    assert!(compact["cells"][0].is_array());
    assert_eq!(compact["cells"][0][2], "A");
    assert_eq!(compact["cells"][0][3], 0x010203);
    t.feed("B");
    let delta = call(json!({"op":"snapshot","id":t.0,"since":compact["revision"],"compact":false}));
    assert_eq!(delta["partial"], true);
    assert!(delta["cells"][0].is_object());
}

#[test]
fn cursor_erase_and_truecolor() {
    let t = Terminal::new(20, 4);
    t.feed("abcdef\x1b[1;3H\x1b[K\x1b[38;2;1;2;3mZ");
    let s = t.snapshot();
    assert_eq!(s["lines"][0], "abZ                 ");
    // Cells are [row, col, text, fg, bg, attrs, ...] with 0xRRGGBB colours.
    assert_eq!(s["cells"][2][3], 0x010203);
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
    assert_eq!(s["cells"][0][5], 16, "wide");
    assert_eq!(s["cells"][1][2], "");
    assert_eq!(s["cells"][2][2], "e\u{301}");
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
fn bell_is_reported_once_and_osc_terminators_do_not_ring() {
    let t = Terminal::new(20, 3);
    t.feed("\x1b]0;title\x07\x1b]52;c;aGVsbG8=\x07");
    assert_eq!(t.snapshot()["bell"], false, "BEL ending an OSC string is a terminator");
    t.feed("\x07");
    assert_eq!(t.snapshot()["bell"], true);
    assert_eq!(t.snapshot()["bell"], false);
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
fn find_moves_between_literal_matches_and_highlights_the_current_one() {
    let t = Terminal::new(20, 4);
    t.feed("one two one\r\nnope\r\nwide 界 end");
    let latest = call(json!({"op":"find","id":t.0,"text":"one"}));
    assert_eq!(latest["col"], 8, "the latest hit is the rightmost one");
    assert_eq!(latest["end_col"], 11);
    assert_eq!(latest["wrapped"], false);
    let marked = |row: i64, col: i64| {
        t.snapshot()["cells"].as_array().unwrap().iter().find(|cell| cell[0] == row && cell[1] == col).unwrap()[5].as_u64().unwrap()
    };
    let row = latest["row"].as_i64().unwrap();
    assert_eq!(marked(row, 8) & 192, 192, "the current hit is the active highlight");
    assert_eq!(marked(row, 0) & 192, 64, "an earlier hit on the same row is highlighted, not active");
    assert_eq!(marked(row, 4) & 64, 0, "text that is not the query stays unmarked");
    let previous = call(json!({"op":"find","id":t.0,"text":"one","direction":"previous"}));
    assert_eq!(previous["col"], 0);
    assert_eq!(previous["wrapped"], false);
    let wrapped = call(json!({"op":"find","id":t.0,"text":"one","direction":"previous"}));
    assert_eq!(wrapped["col"], 8);
    assert_eq!(wrapped["wrapped"], true);
    let next = call(json!({"op":"find","id":t.0,"text":"one","direction":"next"}));
    assert_eq!(next["col"], 0);
    assert_eq!(next["wrapped"], true);
    assert_eq!(call(json!({"op":"find","id":t.0,"text":"One"}))["found"], false, "matching stays case sensitive");
    let wide = call(json!({"op":"find","id":t.0,"text":"界"}));
    assert_eq!(wide["found"], true);
    assert_eq!(wide["end_col"].as_u64().unwrap() - wide["col"].as_u64().unwrap(), 2, "a wide hit covers both columns");
    let wide_row = wide["row"].as_i64().unwrap();
    let wide_col = wide["col"].as_i64().unwrap();
    assert_eq!(marked(wide_row, wide_col) & 192, 192);
    assert_eq!(marked(wide_row, wide_col + 1) & 64, 64, "the wide spacer is highlighted too");
    t.feed("\r\n");
    for _ in 0..6 { t.feed("pad\r\n"); }
    let buried = call(json!({"op":"find","id":t.0,"text":"needle-absent"}));
    assert_eq!(buried["found"], false);
    let brought = call(json!({"op":"find","id":t.0,"text":"wide"}));
    assert_eq!(brought["found"], true);
    let shown = brought["row"].as_i64().unwrap();
    assert!((0..4).contains(&shown), "a hit in scrollback is scrolled into view");
    assert_eq!(call(json!({"op":"find","id":t.0,"clear":true}))["found"], false);
    let cleared = t.snapshot();
    assert!(cleared["cells"].as_array().unwrap().iter().all(|cell| cell[5].as_u64().unwrap() & 64 == 0));
    assert_eq!(response(json!({"op":"find","id":t.0,"text":"one","direction":"sideways"}))["ok"], false);
    assert_eq!(response(json!({"op":"find","id":t.0,"text":""}))["ok"], false);
}
#[test]
fn find_active_mark_does_not_stick_to_scrolled_in_text() {
    let t = Terminal::new(20, 4);
    t.feed("one two one");
    assert_eq!(call(json!({"op":"find","id":t.0,"text":"one"}))["col"], 8);
    // The ring scrolls the match into history and puts other text on its old line.
    t.feed("\r\nzzzzzzzzzzzz\r\n\r\n\r\n");
    let scrolled = t.snapshot();
    let cells = scrolled["cells"].as_array().unwrap();
    assert!(
        cells.iter().all(|cell| cell[5].as_u64().unwrap() & 128 == 0),
        "the active highlight must not stay on the line that scrolled in"
    );
    assert!(cells.iter().filter(|cell| cell[2] == "z").all(|cell| cell[5].as_u64().unwrap() & 64 == 0));
    let again = call(json!({"op":"find","id":t.0,"text":"one","direction":"next"}));
    assert_eq!(again["found"], true);
    assert!((0..4).contains(&again["row"].as_i64().unwrap()), "next starts over and brings the match back");
    let shown = t.snapshot();
    let active: Vec<_> = shown["cells"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|cell| cell[5].as_u64().unwrap() & 128 != 0)
        .map(|cell| cell[2].as_str().unwrap().to_string())
        .collect();
    assert_eq!(active, vec!["o".to_string(), "n".to_string(), "e".to_string()]);
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
    let request = serde_json::to_vec(&json!({"op":"snapshot","id":t.0,"compact":true})).unwrap();
    let buffer = unsafe { akitty_core::akitty_request_v1(request.as_ptr(), request.len()) };
    assert!(!buffer.data.is_null());
    let bytes = unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) }.to_vec();
    unsafe { akitty_core::akitty_buffer_free_v1(buffer) };
    let response: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(response["ok"], true, "{}", String::from_utf8_lossy(&bytes[..bytes.len().min(200)]));
    assert!(bytes.len() < 8 * 1024 * 1024);
    // The ABI splices pre-serialized snapshot JSON into the envelope; it must match the value path exactly.
    assert_eq!(response, self::response(json!({"op":"snapshot","id":t.0,"compact":true})));
    // Bold, italic, underline, strike and underline style 3 in attrs, then the underline colour and link index.
    assert_eq!(response["data"]["cells"][0], json!([0, 0, "x", 0xdae2ef, 0x12161d, 1 | 2 | 4 | 32 | 3 << 8, 0x010203, 0]));
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

fn rgba(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn chrome(id: u64, document: Value) -> Value {
    let mut body = document;
    body["op"] = json!("chrome");
    body["id"] = json!(id);
    response(body)
}

#[test]
fn chrome_sequence_and_abi_replace_clear_and_expire_without_changing_title() {
    let t = Terminal::new(24, 4);
    // Push the default (unset) title, then set one, so a later pop is a real reset.
    t.feed("\x1b[22t\x1b]2;vim\x07");
    let seq = "\x1b]771;{\"status\":{\"text\":\"hel\\u0001lo\\n\",\"tone\":\"info\"},\"progress\":0.5}\x07OK";
    t.feed(&seq[..8]);
    t.feed(&seq[8..]);
    let snap = t.snapshot();
    assert_eq!(snap["title"], "vim");
    assert!(snap["lines"][0].as_str().unwrap().starts_with("OK"), "{}", snap["lines"][0]);
    assert!(!snap["lines"][0].as_str().unwrap().contains("771"));
    assert_eq!(snap["chrome"]["status"]["text"], "hello");
    assert_eq!(snap["chrome"]["status"]["tone"], "info");
    assert_eq!(snap["chrome"]["progress"], json!(0.5));
    // String terminator form, and a full replacement drops fields the new document omits.
    t.feed("\x1b]771;{\"mark\":\"busy\"}\x1b\\");
    let snap = t.snapshot();
    assert_eq!(snap["title"], "vim");
    assert!(snap["chrome"].get("status").is_none());
    assert!(snap["chrome"].get("progress").is_none());
    assert_eq!(snap["chrome"]["mark"], "busy");
    let pixel = rgba(&[9, 8, 7, 255]);
    let other = rgba(&[1, 2, 3, 255]);
    assert_eq!(
        chrome(t.0, json!({"sprite": {"w": 1, "h": 1, "frames": [pixel, other]}, "mark": 1, "status": {"text": &"x".repeat(140), "tone": "warn", "expires": 4_102_444_800_000u64}, "progress": "indeterminate"}))["ok"],
        true
    );
    let snap = t.snapshot();
    assert_eq!(snap["chrome"]["status"]["text"], json!("x".repeat(128)));
    assert_eq!(snap["chrome"]["status"]["tone"], "warn");
    assert_eq!(snap["chrome"]["mark"], 1);
    assert_eq!(snap["chrome"]["progress"], "indeterminate");
    assert_eq!(snap["chrome"]["sprite"]["w"], 1);
    assert_eq!(snap["chrome"]["sprite"]["frames"][0], json!(pixel));
    assert_eq!(snap["title"], "vim");
    // Already-past expiry removes the status and the progress, and keeps the mark.
    assert_eq!(chrome(t.0, json!({"status": {"text": "gone", "tone": "error", "expires": 0}, "progress": 1.0, "mark": "idle"}))["ok"], true);
    let snap = t.snapshot();
    assert!(snap["chrome"].get("status").is_none(), "{snap}");
    assert!(snap["chrome"].get("progress").is_none(), "{snap}");
    assert_eq!(snap["chrome"]["mark"], "idle");
    assert!(snap["chrome"].get("sprite").is_none());
    assert_eq!(chrome(t.0, json!({"clear": true}))["ok"], true);
    assert!(t.snapshot().get("chrome").is_none());
    t.feed("\x1b[23t");
    let snap = t.snapshot();
    assert_eq!(snap["title"], "Akitty");
    assert!(snap.get("chrome").is_none());
}

#[test]
fn chrome_rejects_sprite_limits_and_external_sources_without_replacing() {
    let t = Terminal::new(20, 3);
    assert_eq!(chrome(t.0, json!({"status": {"text": "kept", "tone": "info"}, "sprite": {"w": 1, "h": 1, "frames": [rgba(&[4, 5, 6, 7])]}}))["ok"], true);
    let too_wide = rgba(&[0u8; 33 * 4]);
    let five = vec![rgba(&[1, 1, 1, 1]); 5];
    for document in [
        json!({"sprite": {"w": 33, "h": 1, "frames": [too_wide]}}),
        json!({"sprite": {"w": 1, "h": 1, "frames": five}}),
        json!({"sprite": {"w": 0, "h": 1, "frames": [rgba(&[1, 1, 1, 1])]}}),
        json!({"sprite": {"w": 1, "h": 1, "frames": [rgba(&[1, 2, 3])]}}),
        json!({"sprite": {"w": 1, "h": 1, "path": "/tmp/akitty.png", "frames": [rgba(&[1, 1, 1, 1])]}}),
        json!({"sprite": {"w": 1, "h": 1, "url": "https://example.com/a.png"}}),
        json!({"sprite": {"w": 1, "h": 1, "shm": "kit", "source": "shm"}}),
        json!({"sprite": {"w": 1, "h": 1, "source": "file", "file": "local.png"}}),
        json!({"progress": 1.5}),
        json!({"mark": 4}),
        json!({"status": {"text": "nope", "tone": "fatal"}}),
        json!({"video": true}),
    ] {
        let reply = chrome(t.0, document);
        assert_eq!(reply["ok"], false, "{reply}");
    }
    // A rejected terminal sequence is consumed and does not replace the document or the title.
    t.feed("\x1b]2;shell\x07");
    t.feed("\x1b]771;{\"sprite\":{\"w\":1,\"h\":1,\"url\":\"https://example.com/x.png\"}}\x07NO");
    let snap = t.snapshot();
    assert_eq!(snap["title"], "shell");
    assert_eq!(snap["chrome"]["status"]["text"], "kept");
    assert_eq!(snap["chrome"]["sprite"]["frames"][0], json!(rgba(&[4, 5, 6, 7])));
    assert!(snap["lines"][0].as_str().unwrap().starts_with("NO"), "{}", snap["lines"][0]);
}

#[test]
fn program_chrome_off_ignores_the_terminal_sequence_but_not_the_abi() {
    let t = Terminal::new(20, 3);
    call(json!({"op": "program_chrome", "id": t.0, "enabled": false}));
    t.feed("\x1b]771;{\"status\":{\"text\":\"from-program\",\"tone\":\"info\"}}\x07");
    assert!(t.snapshot().get("chrome").is_none());
    assert_eq!(chrome(t.0, json!({"status": {"text": "from-host", "tone": "error"}, "progress": 0}))["ok"], true);
    let snap = t.snapshot();
    assert_eq!(snap["chrome"]["status"]["text"], "from-host");
    assert_eq!(snap["chrome"]["progress"], json!(0.0));
    t.feed("\x1b]771;{\"clear\":true}\x07");
    assert_eq!(t.snapshot()["chrome"]["status"]["text"], "from-host");
    call(json!({"op": "program_chrome", "id": t.0, "enabled": true}));
    t.feed("\x1b]771;{\"status\":{\"text\":\"program-again\",\"tone\":\"warn\"}}\x07");
    assert_eq!(t.snapshot()["chrome"]["status"]["text"], "program-again");
}

#[test]
fn long_osc_52_sets_the_clipboard() {
    let t = Terminal::new(20, 3);
    let text = "A".repeat(50_000);
    let payload = base64::engine::general_purpose::STANDARD.encode(text.as_bytes());
    let wire = format!("\x1b]52;c;{payload}\x07");
    // 50_000 bytes is under the decoded clipboard cap. Base64 makes the wire longer than the OSC 771 body cap.
    assert_eq!(wire.len(), 66_676);
    t.feed(&wire);
    t.feed("\x1b]2;vim\x07OK");
    let snap = t.snapshot();
    assert_eq!(snap["clipboard"], json!([text]));
    assert_eq!(snap["title"], "vim");
    assert!(snap["lines"][0].as_str().unwrap().starts_with("OK"), "{}", snap["lines"][0]);
    assert!(!snap["lines"][0].as_str().unwrap().contains('A'));
}
