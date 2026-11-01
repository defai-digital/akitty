pub use akitty_agent_core::program_status::*;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Model, Size};
    use serde_json::json;
    #[test]
    fn stream_queries_lifecycle_and_resets_preserve_host_authority() {
        let mut model = Model::new(Size { cols: 20, rows: 3 }, 0);
        assert_eq!(model.feed(b"\x1b]7501;?\x1b\\"), REPLY);
        for byte in b"\x1b]7501;state=blocked:kind=permission:app=agent\x1b\\" { model.feed(&[*byte]); }
        model.feed(b"\x1b]7501;state=done:id=task\x07");
        assert_eq!(model.snapshot(None)["control"]["owner"], "human");
        assert_eq!(model.snapshot(None)["program_status"]["records"].as_array().unwrap().len(), 2);
        model.feed(b"\x1b[?1049h\x1b[?1049l\x1b[!p");
        assert_eq!(model.snapshot(None)["program_status"]["records"].as_array().unwrap().len(), 2);
        model.feed(b"\x1b]133;A\x07");
        assert_eq!(model.snapshot(None)["program_status"]["records"][0]["state"], "done");
        model.feed(b"\x1bc");
        assert_eq!(model.snapshot(None)["program_status"]["records"], json!([]));
        model.set_program_chrome(false);
        assert!(model.feed(b"\x1b]7501;?\x07").is_empty());
        model.feed(b"\x1b]7501;state=done\x07");
        assert_eq!(model.snapshot(None)["program_status"]["records"], json!([]));
    }

    #[test]
    fn oversized_cancelled_and_malformed_status_never_enters_grid_or_changes_state() {
        let mut model = Model::new(Size { cols: 20, rows: 3 }, 0);
        model.feed(b"\x1b]7501;state=idle\x07");
        let before = model.snapshot(None)["program_status"].clone();
        model.feed(format!("\x1b]7501;state=error:unknown={}\x1b\\", "x".repeat(4096)).as_bytes());
        model.feed(b"\x1b]7501;state=error\x18visible");
        assert_eq!(model.snapshot(None)["program_status"], before);
        let snapshot = model.snapshot(None);
        assert!(snapshot["lines"][0].as_str().unwrap().starts_with("visible"));
        model.exited = true;
        assert_eq!(model.snapshot(None)["program_status"]["records"], json!([]));
    }
}
