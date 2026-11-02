//! OSC 7501 revision 0.4: bounded, forgeable program reports, never host authority.
use base64::Engine;
use base64::engine::general_purpose::STANDARD_NO_PAD;
use serde::Serialize;
use serde_json::{Value, json};

pub const REPLY: &[u8] = b"\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x1b\\";
const MAX_RECORDS: usize = 256;

#[derive(Clone, Serialize)]
struct Record {
    id: String,
    state: String,
    app: Option<String>,
    title: Option<String>,
    msg: Option<String>,
    kind: Option<String>,
    progress: Option<u8>,
}

#[derive(Default)]
pub struct ProgramStatuses {
    // Least recently updated first; replacement moves a record to the end.
    records: Vec<Record>,
}

fn identifier(value: &str, path: bool) -> bool {
    value.len() <= if path { 128 } else { 32 }
        && value.split('/').count() <= if path { 8 } else { 1 }
        && value.split('/').all(|part| !part.is_empty() && part.len() <= 32
            && part.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(&b)))
}

fn text(value: &str, encoded_limit: usize, decoded_limit: usize) -> Option<String> {
    if value.len() > encoded_limit { return None; }
    let bytes = STANDARD_NO_PAD.decode(value.trim_end_matches('=')).ok()?;
    // Only optional standard padding is allowed, not arbitrary '=' suffixes.
    let padding = value.len() - value.trim_end_matches('=').len();
    if padding > 2 || (padding > 0 && !value.len().is_multiple_of(4)) || bytes.len() > decoded_limit { return None; }
    let text = String::from_utf8(bytes).ok()?;
    (!text.chars().any(char::is_control)).then_some(text)
}

impl ProgramStatuses {
    pub fn apply(&mut self, bytes: &[u8]) {
        let Ok(body) = std::str::from_utf8(bytes) else { return };
        let mut pairs = std::collections::BTreeMap::new();
        for pair in body.split(':') {
            let Some((key, value)) = pair.split_once('=') else { continue };
            let (key, value) = (key.trim(), value.trim());
            if key.len() > 16 { return; }
            if key.is_empty() || !key.bytes().all(|b| b.is_ascii_lowercase())
                || !value.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.,+/=-".contains(&b)) { continue; }
            // Validate every free-text pair before changing stored state, even overwritten ones.
            if (key == "msg" && text(value, 2732, 2048).is_none())
                || (key == "title" && text(value, 256, 192).is_none()) { return; }
            if key == "id" && value.len() > 128 { return; }
            if key == "app" && value.len() > 32 { return; }
            pairs.insert(key, value);
        }
        let Some(&state) = pairs.get("state") else { return };
        if !["idle", "working", "blocked", "done", "error", "clear"].contains(&state) { return; }
        let id = pairs.get("id").copied().unwrap_or("");
        if pairs.contains_key("id") && !identifier(id, true) { return; }
        if state == "clear" {
            self.records.retain(|record| !(id.is_empty() || record.id == id || record.id.starts_with(&format!("{id}/"))));
            return;
        }
        let record = Record {
            id: id.into(), state: state.into(),
            app: pairs.get("app").filter(|value| identifier(value, false)).map(|value| (*value).into()),
            title: pairs.get("title").and_then(|value| text(value, 256, 192)),
            msg: pairs.get("msg").and_then(|value| text(value, 2732, 2048)),
            kind: pairs.get("kind").filter(|value| state == "blocked" && ["permission", "question", "auth"].contains(value)).map(|value| (*value).into()),
            progress: pairs.get("progress").filter(|_| state == "working" || state == "blocked")
                .filter(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
                .and_then(|value| value.parse::<u8>().ok()).filter(|value| *value <= 100),
        };
        self.records.retain(|record| record.id != id);
        if self.records.len() == MAX_RECORDS { self.records.remove(0); }
        self.records.push(record);
    }

    pub fn finish_work(&mut self) { self.records.retain(|record| record.state == "done" || record.state == "error"); }
    pub fn clear(&mut self) { self.records.clear(); }

    pub fn to_json(&self) -> Value {
        let records: Vec<Value> = self.records.iter().map(|record| {
            let mut value = serde_json::to_value(record).expect("program status serializes");
            // Inheritance is resolved at read time, so removing/replacing a parent takes effect.
            if record.app.is_none() {
                let mut id = record.id.as_str();
                while !id.is_empty() {
                    id = id.rsplit_once('/').map_or("", |(parent, _)| parent);
                    if let Some(app) = self.records.iter().find(|parent| parent.id == id).and_then(|parent| parent.app.as_ref()) {
                        value["app"] = json!(app); break;
                    }
                }
            }
            value
        }).collect();
        json!({"source":"osc7501", "untrusted":true, "records":records})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_replace_inherit_and_clear_only_the_addressed_subtree() {
        let mut status = ProgramStatuses::default();
        status.apply(b"state=working:app=builder:msg=cm9vdA==");
        status.apply(b"state=blocked:id=build/test:kind=permission:progress=25");
        status.apply(b"state=done:id=other:app=other");
        assert_eq!(status.to_json()["records"][1]["app"], "builder");
        status.apply(b"state=error:id=build/test");
        let json = status.to_json();
        let child = json["records"].as_array().unwrap().iter().find(|r| r["id"] == "build/test").unwrap();
        assert!(child["kind"].is_null());
        assert!(child["progress"].is_null());
        status.apply(b"state=clear:id=build");
        assert_eq!(status.to_json()["records"].as_array().unwrap().len(), 2);
        status.apply(b"state=clear");
        assert_eq!(status.to_json()["records"], json!([]));
    }

    #[test]
    fn malformed_reports_cannot_partially_replace_records_or_fall_back_to_root() {
        let mut status = ProgramStatuses::default();
        status.apply(b"state=idle:app=root");
        let before = status.to_json();
        for report in ["state=done:msg=G0E=", "state=done:msg=woA=", "state=done:msg=YQ===",
            "state=error:id=bad//id", "state=unknown", "app=missing-state", "state=done:title=/w==",
            "state=done:msg=bad:msg=b2s=", "state=done:unknownlongkeyname=ok"] {
            status.apply(report.as_bytes());
            assert_eq!(status.to_json(), before, "{report}");
        }
        status.apply(b"broken:state=working:future=ok:state=blocked:kind=unsupported:progress=101");
        let value = status.to_json();
        assert_eq!(value["records"][0]["state"], "blocked");
        assert!(value["records"][0]["app"].is_null(), "replacement clears omitted app");
        assert!(value["records"][0]["kind"].is_null());
        assert!(value["records"][0]["progress"].is_null());
    }

    #[test]
    fn bounded_records_evict_least_recently_updated_and_validate_text_limits() {
        let mut status = ProgramStatuses::default();
        for i in 0..256 { status.apply(format!("state=done:id=task{i}").as_bytes()); }
        status.apply(b"state=done:id=task0");
        status.apply(b"state=done:id=extra");
        let value = status.to_json();
        let records = value["records"].as_array().unwrap();
        assert_eq!(records.len(), 256);
        assert!(!records.iter().any(|r| r["id"] == "task1"));
        assert!(records.iter().any(|r| r["id"] == "task0"));
        let before = status.to_json();
        status.apply(format!("state=done:msg={}", STANDARD_NO_PAD.encode(vec![b'x'; 2049])).as_bytes());
        assert_eq!(status.to_json(), before);
        status.apply(format!("state=done:app={}", "x".repeat(33)).as_bytes());
        assert_eq!(status.to_json(), before);
    }

}
