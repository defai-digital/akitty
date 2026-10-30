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
