//! Authored protocol fixtures are executed against native Rust and the actual
//! browser WASM binary (scripts/test-vt-wasm.mjs), including byte segmentation.
use akitty_vt::{Event, Terminal};
use serde_json::Value;

#[test]
fn shared_protocol_contracts() {
    let fixtures: Vec<Value> = serde_json::from_str(include_str!("fixtures/streams.json")).unwrap();
    for fixture in fixtures {
        let input = fixture["input"].as_str().unwrap().as_bytes();
        for split in 0..=input.len() {
            let mut term = Terminal::new(
                fixture["cols"].as_u64().unwrap() as usize,
                fixture["rows"].as_u64().unwrap() as usize,
                fixture["history_limit"].as_u64().unwrap() as usize,
            )
            .unwrap();
            term.enable_grapheme_support(fixture["graphemes"].as_bool().unwrap_or(false));
            let mut replies = Vec::new();
            for chunk in [&input[..split], &input[split..]] {
                term.feed(chunk, 0, |event| {
                    if let Event::Reply(bytes) = event {
                        replies.extend(bytes);
                    }
                });
            }
            let lines: Vec<_> = term.screen().rows.iter().map(|row| row.text()).collect();
            assert_eq!(
                serde_json::json!(lines),
                fixture["lines"],
                "{} split {split}",
                fixture["name"]
            );
            assert_eq!(
                serde_json::json!([term.cursor().col, term.cursor().row]),
                fixture["cursor"],
                "{} split {split}",
                fixture["name"]
            );
            assert_eq!(
                String::from_utf8(replies).unwrap(),
                fixture["replies"].as_str().unwrap(),
                "{} split {split}",
                fixture["name"]
            );
            assert_eq!(
                term.screen().history.len() as u64,
                fixture["history"].as_u64().unwrap(),
                "{} split {split}",
                fixture["name"]
            );
        }
    }
}

#[test]
fn random_edits_resizes_and_screen_switches_preserve_grid_invariants() {
    let mut term = Terminal::new(12, 6, 10).unwrap();
    let commands = [
        "x",
        "中",
        "😀",
        "e\u{301}",
        "\x1b[?2027h",
        "\x1b[?2027l",
        "👩🏽‍💻",
        "🇯🇵",
        "❤️",
        "\r",
        "\n",
        "\x08",
        "\t",
        "\x1b[2@",
        "\x1b[2P",
        "\x1b[2X",
        "\x1b[2J",
        "\x1b[3J",
        "\x1b[2K",
        "\x1b[2L",
        "\x1b[2M",
        "\x1b[3S",
        "\x1b[3T",
        "\x1b[H",
        "\x1b[99;99H",
        "\x1b[2;4r",
        "\x1b[r",
        "\x1b[?1049h",
        "\x1b[?1049l",
        "\x1b[?6h",
        "\x1b[?6l",
        "\x1b[?7h",
        "\x1b[?7l",
    ];
    term.enable_grapheme_support(true);
    let mut random = 0x5a17_c301_u32;
    for index in 0..10_000 {
        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        if random.is_multiple_of(19) {
            term.resize(
                1 + random as usize % 25,
                1 + (random >> 8) as usize % 10,
                |_| {},
            )
            .unwrap();
        } else {
            term.feed(
                commands[random as usize % commands.len()].as_bytes(),
                index,
                |_| {},
            );
        }
        let screen = term.screen();
        assert!(
            term.cursor().row < term.rows() && term.cursor().col < term.cols(),
            "step {index}"
        );
        assert!(
            screen.region.start < screen.region.end && screen.region.end <= term.rows(),
            "step {index}"
        );
        assert!(screen.history.len() <= 10);
        for row in screen.history.iter().chain(&screen.rows) {
            assert_eq!(row.cells.len(), term.cols(), "step {index}");
            for (col, cell) in row.cells.iter().enumerate() {
                if cell.width == 0 {
                    assert!(
                        col > 0 && row.cells[col - 1].width == 2,
                        "orphan trail step {index} col {col}"
                    );
                }
                if cell.width == 2 {
                    assert!(
                        col + 1 < term.cols() && row.cells[col + 1].width == 0,
                        "orphan lead step {index} col {col}"
                    );
                }
                assert!(cell.combining.len() <= akitty_vt::cell::MAX_COMBINING);
            }
        }
    }
}
