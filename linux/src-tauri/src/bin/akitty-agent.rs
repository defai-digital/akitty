use akitty_linux_experimental::ipc;
use serde_json::json;
use std::path::PathBuf;

fn main() {
    let result = run();
    match result {
        Ok(value) => { println!("{value}"); if value["ok"] != true { std::process::exit(1); } }
        Err(error) => { eprintln!("{error}"); std::process::exit(1); }
    }
}
fn run() -> Result<serde_json::Value, String> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let path = if args.first().is_some_and(|s| s == "--socket") {
        if args.len() < 3 { return Err("--socket requires a path and operation".into()); }
        let path = PathBuf::from(&args[1]); args.drain(..2); path
    } else { ipc::default_socket()? };
    let request = match args.as_slice() {
        [operation] if operation == "list" => json!({"version":1,"op":"list"}),
        [operation, offset] if operation == "list" => json!({"version":1,"op":"list","offset":offset.parse::<usize>().map_err(|_| "invalid offset")?}),
        [operation, pane, command] if operation == "request" => {
            akitty_linux_experimental::validate_command(command)?;
            json!({"version":1,"op":"request","pane":pane,"command":command})
        }
        _ => return Err("usage: akitty-agent [--socket PATH] list [OFFSET] | request PANE 'EXACT COMMAND'".into()),
    };
    ipc::call(&path, &request)
}
