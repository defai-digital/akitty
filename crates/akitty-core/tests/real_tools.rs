//! Smoke tests against real Kitty graphics clients (kitten icat, chafa, timg, viu) in a real PTY.
//!
//! Ignored by default: they need the tools installed and a shell. Run with
//! `cargo test --locked --test real_tools -- --ignored --test-threads=1`. A missing tool is skipped, not failed.
use akitty_core::request;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn call(value: Value) -> Value {
    let response = request(&serde_json::to_vec(&value).unwrap());
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}

fn tool(name: &str) -> Option<PathBuf> {
    ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].iter().map(|dir| Path::new(dir).join(name)).find(|path| path.exists())
}

/// A 64x48 gradient PNG with an alpha edge, written once per test.
fn fixture(dir: &Path) -> PathBuf {
    let path = dir.join("akitty-smoke.png");
    let file = std::fs::File::create(&path).unwrap();
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), 64, 48);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().unwrap();
    let pixels: Vec<u8> = (0..48u32)
        .flat_map(|y| (0..64u32).flat_map(move |x| [(x * 4) as u8, (y * 5) as u8, 128, if x < 4 { 0 } else { 255 }]))
        .collect();
    writer.write_image_data(&pixels).unwrap();
    path
}

/// Runs `command` in a real shell with 16x32 device-pixel cells and returns the first snapshot showing an image.
fn run(command: &str) -> Value {
    let dir = std::env::temp_dir();
    let id = call(json!({"op":"create","cols":100,"rows":30,"shell":"/bin/sh","cwd":dir.to_str().unwrap()}))["id"]
        .as_u64()
        .unwrap();
    call(json!({"op":"cell_size","id":id,"width":16,"height":32}));
    call(json!({"op":"input","id":id,"text":format!("{command}\r")}));
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut last = Value::Null;
    while Instant::now() < deadline {
        let snapshot = call(json!({"op":"snapshot","id":id}));
        if snapshot["images"].as_array().is_some_and(|images| !images.is_empty()) {
            call(json!({"op":"close","id":id}));
            return snapshot;
        }
        last = snapshot;
        std::thread::sleep(Duration::from_millis(50));
    }
    call(json!({"op":"close","id":id}));
    panic!("`{command}` drew no image; last screen: {}", last["lines"]);
}

fn check(name: &str, args: &str) {
    let Some(path) = tool(name) else {
        eprintln!("skipping {name}: not installed");
        return;
    };
    let image = fixture(&std::env::temp_dir());
    let snapshot = run(&format!("{} {args} {}", path.display(), image.display()));
    let placement = &snapshot["images"][0];
    eprintln!("{name}: {placement}");
    assert!(placement["w"].as_u64().unwrap() > 0 && placement["cols"].as_u64().unwrap() > 0, "{placement}");
}

#[test]
#[ignore]
fn kitten_icat_draws_with_its_default_transfer_detection() {
    check("kitten", "icat --stdin=no");
}

#[test]
#[ignore]
fn kitten_icat_draws_over_a_stream() {
    check("kitten", "icat --stdin=no --transfer-mode=stream");
}

#[test]
#[ignore]
fn kitten_icat_draws_through_a_temp_file() {
    check("kitten", "icat --stdin=no --transfer-mode=file");
}

#[test]
#[ignore]
fn kitten_icat_draws_through_shared_memory() {
    check("kitten", "icat --stdin=no --transfer-mode=memory");
}

#[test]
#[ignore]
fn kitten_icat_draws_unicode_placeholders() {
    check("kitten", "icat --stdin=no --unicode-placeholder");
}

#[test]
#[ignore]
fn chafa_draws_in_kitty_format() {
    check("chafa", "-f kitty");
}

#[test]
#[ignore]
fn timg_draws_with_the_kitty_protocol() {
    check("timg", "-pk");
}

#[test]
#[ignore]
fn viu_draws_when_told_it_is_kitty() {
    let Some(path) = tool("viu") else { return eprintln!("skipping viu: not installed") };
    let image = fixture(&std::env::temp_dir());
    let snapshot = run(&format!("KITTY_WINDOW_ID=1 {} {}", path.display(), image.display()));
    eprintln!("viu: {}", snapshot["images"][0]);
}
