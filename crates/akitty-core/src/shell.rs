//! Shell notifications are untrusted observations, independent of host authorization.
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::VecDeque;

const RECORDS: usize = 64;
const OUTPUT: usize = 16_384;

#[derive(Serialize)]
pub struct CommandRecord {
    pub id: u64,
    pub command: String,
    pub cwd: Option<String>,
    pub started_ms: u64,
    pub ended_ms: Option<u64>,
    pub exit_code: Option<u8>,
    pub interrupted: bool,
    pub truncated: bool,
    #[serde(skip)]
    output: Vec<u8>,
}

#[derive(Default)]
pub struct Shell {
    pub cwd: Option<String>,
    pub ready: bool,
    next: u64,
    pending: String,
    records: VecDeque<CommandRecord>,
    pub rejected: u64,
}
impl Shell {
    fn active(&mut self) -> Option<&mut CommandRecord> {
        self.records.back_mut().filter(|record| record.ended_ms.is_none())
    }
    pub fn output(&mut self, data: &[u8]) {
        if let Some(record) = self.active() {
            let available = OUTPUT - record.output.len();
            record.output.extend_from_slice(&data[..data.len().min(available)]);
            record.truncated |= data.len() > available;
        }
    }
    pub fn finish(&mut self) {
        if let Some(record) = self.active() {
            record.ended_ms = Some(crate::chrome::now_ms());
            record.interrupted = true;
        }
        self.ready = false;
        self.pending.clear();
    }
    pub fn observe(&mut self, body: &[u8]) {
        if body.len() > 8192 || self.apply(body).is_err() { self.rejected = self.rejected.saturating_add(1); }
    }
    fn apply(&mut self, body: &[u8]) -> Result<(), ()> {
        let body = std::str::from_utf8(body).map_err(|_| ())?;
        if let Some(value) = body.strip_prefix("7;") {
            self.cwd = Some(directory(value)?);
        } else if let Some(value) = body.strip_prefix("772;") {
            let bytes = STANDARD.decode(value).map_err(|_| ())?;
            if bytes.len() > 4096 { return Err(()); }
            let text = String::from_utf8(bytes).map_err(|_| ())?;
            if text.chars().any(|c| c.is_control()) { return Err(()); }
            self.pending = text;
        } else {
            match body {
                "133;A" => { self.finish(); self.ready = true; }
                "133;B" => {},
                "133;C" => {
                    let command = std::mem::take(&mut self.pending);
                    self.finish();
                    self.next = self.next.checked_add(1).ok_or(())?;
                    if self.records.len() == RECORDS { self.records.pop_front(); }
                    self.records.push_back(CommandRecord { id: self.next, command,
                        cwd: self.cwd.clone(), started_ms: crate::chrome::now_ms(), ended_ms: None,
                        exit_code: None, interrupted: false, truncated: false, output: Vec::new() });
                },
                value if value.starts_with("133;D") => {
                    let code = match value.strip_prefix("133;D;") {
                        Some(code) => Some(code.parse::<u8>().map_err(|_| ())?),
                        None if value == "133;D" => None,
                        _ => return Err(()),
                    };
                    if let Some(record) = self.active() {
                        record.ended_ms = Some(crate::chrome::now_ms()); record.exit_code = code;
                    }
                    self.ready = false;
                },
                _ => return Err(()),
            }
        }
        Ok(())
    }
    pub fn summary(&self) -> Value {
        json!({"cwd":self.cwd,"ready":self.ready,"last_command_id":self.next,"rejected":self.rejected,"untrusted":true})
    }
    pub fn history(&self, after: u64) -> Value {
        json!({"commands":self.records.iter().filter(|r| r.id > after).collect::<Vec<_>>(),
            "oldest_id":self.records.front().map(|r|r.id),"last_id":self.next,"untrusted":true})
    }
    pub fn command_output(&self, id: u64) -> Result<Value, String> {
        let record = self.records.iter().find(|r|r.id == id).ok_or("unknown or evicted command")?;
        Ok(json!({"command_id":id,"output_base64":STANDARD.encode(&record.output),"truncated":record.truncated,
            "complete":record.ended_ms.is_some(),"untrusted":true}))
    }
}

fn directory(uri: &str) -> Result<String, ()> {
    let tail = uri.strip_prefix("file://").ok_or(())?;
    let slash = tail.find('/').ok_or(())?;
    let host = &tail[..slash];
    if host.len() > 255 || !host.bytes().all(|b|b.is_ascii_alphanumeric() || b".-_".contains(&b)) { return Err(()); }
    let raw = &tail.as_bytes()[slash..];
    if raw.len() > 4096 || raw.contains(&b'?') || raw.contains(&b'#') { return Err(()); }
    let mut bytes = Vec::new(); let mut index = 0;
    while index < raw.len() {
        if raw[index] == b'%' {
            let hex = raw.get(index+1..index+3).ok_or(())?;
            bytes.push(u8::from_str_radix(std::str::from_utf8(hex).map_err(|_| ())?,16).map_err(|_| ())?); index += 3;
        } else { bytes.push(raw[index]); index += 1; }
    }
    let path = String::from_utf8(bytes).map_err(|_| ())?;
    if path.chars().any(|c| c.is_control()) { return Err(()); }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn command_metadata_output_bounds_and_untrusted_directory() {
        let mut shell = Shell::default();
        shell.observe(b"7;file://localhost/tmp/a%20b"); shell.observe(b"133;A");
        shell.observe(b"772;ZWNobyBoaQ=="); shell.observe(b"133;C");
        shell.output(&vec![b'x'; OUTPUT+1]); shell.observe(b"133;D;7");
        let records = shell.history(0);
        assert_eq!(records["commands"][0]["command"],"echo hi");
        assert_eq!(records["commands"][0]["cwd"],"/tmp/a b");
        assert_eq!(records["commands"][0]["exit_code"],7);
        assert_eq!(records["commands"][0]["truncated"],true);
        shell.observe(b"7;file:///tmp/%00bad"); assert_eq!(shell.cwd.as_deref(),Some("/tmp/a b"));
        assert_eq!(shell.rejected,1);
    }
}
