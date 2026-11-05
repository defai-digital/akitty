//! Release-mode parser/grid/reflow measurements; hosts and renderers are excluded.
use akitty_vt::Terminal;
use serde_json::{Value, json};
use std::io::{self, Read};
use std::time::Instant;

fn integer(value: &Value, name: &str, min: u64, max: u64) -> Result<usize, String> {
    value[name]
        .as_u64()
        .filter(|n| (min..=max).contains(n))
        .map(|n| n as usize)
        .ok_or_else(|| format!("{name} must be in {min}..={max}"))
}

fn run() -> Result<Value, String> {
    if cfg!(debug_assertions) {
        return Err("build this example in release mode".into());
    }
    let mut bytes = Vec::new();
    io::stdin()
        .take(1_048_577)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > 1_048_576 {
        return Err("benchmark configuration exceeds 1 MiB".into());
    }
    let config: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    let cols = integer(&config, "cols", 16, 512)?;
    let rows = integer(&config, "rows", 4, 256)?;
    let history = integer(&config, "history", 0, 20_000)?;
    let samples = integer(&config, "samples", 3, 200)?;
    let rounds = integer(&config, "rounds", 1, 1024)?;
    let warmup = 3;
    let workloads = config["workloads"]
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= 16)
        .ok_or("expected 1..=16 workloads")?;
    let mut results = Vec::new();
    for workload in workloads {
        let id = workload["id"].as_str().ok_or("missing workload id")?;
        let text = workload["text"]
            .as_str()
            .filter(|v| !v.is_empty() && v.len() <= 16_384)
            .ok_or("workload must contain 1..=16384 UTF-8 bytes")?;
        let mut feed_ns = Vec::new();
        let mut resize_ns = Vec::new();
        let mut state = Value::Null;
        for sample in 0..warmup + samples {
            let mut term = Terminal::new(cols, rows, history).map_err(str::to_owned)?;
            term.enable_grapheme_support(true);
            let start = Instant::now();
            for _ in 0..rounds {
                // Match the WASM export's internal 8 KiB segmentation.
                for chunk in text.as_bytes().chunks(8192) {
                    term.feed(chunk, 0, |_| {});
                }
            }
            let feed = start.elapsed().as_nanos() as u64;
            let start = Instant::now();
            term.resize(cols * 2 / 3, rows, |_| {})
                .map_err(str::to_owned)?;
            term.resize(cols, rows, |_| {}).map_err(str::to_owned)?;
            let resize = start.elapsed().as_nanos() as u64;
            std::hint::black_box(&term);
            if sample >= warmup {
                feed_ns.push(feed);
                resize_ns.push(resize);
            }
            state = json!({"lines":term.screen().rows.iter().map(|r|r.text()).collect::<Vec<_>>(),
                "cursor":[term.cursor().col,term.cursor().row],"history":term.screen().history.len(),
                "alternate":term.modes.alternate});
        }
        results.push(json!({"id":id,"bytes_per_sample":text.len()*rounds,
            "feed_ns":feed_ns,"resize_ns":resize_ns,"state":state}));
    }
    Ok(json!({"results":results}))
}

fn main() {
    match run() {
        Ok(result) => println!("{result}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
