use crate::platform::Pty;
use akitty_agent_core::chrome::{Chrome, Filter, Segment, now_ms};
use akitty_agent_core::control::Control;
use akitty_agent_core::program_status::{self, ProgramStatuses};
use akitty_agent_core::shell::Shell;
use base64::Engine;
use portable_pty::PtySize;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::Path;

const QUEUE: usize = 1_048_576;

pub(crate) struct Session {
    pty: Pty,
    filter: Filter,
    reset_parser: vte::Parser,
    chrome: Chrome,
    status: ProgramStatuses,
    pub shell: Shell,
    pub control: Control,
    pub exited: bool,
    pub error: Option<String>,
    pub audit_after: u64,
    pub report_counts: Value,
    pub event_id: String,
    input: VecDeque<u8>,
    output: VecDeque<u8>,
    delivery: Vec<u8>,
    sequence: u64,
    pub program_reports: bool,
}

fn size(cols: u16, rows: u16) -> Result<PtySize, String> {
    if cols == 0 || rows == 0 || cols > 500 || rows > 300 { return Err("invalid terminal dimensions".into()); }
    Ok(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
}

impl Session {
    pub fn new(shell: &str, cwd: &Path, integration: &Path, event_id: String) -> Result<Self, String> {
        let pty = Pty::new(shell, cwd, integration, size(80, 24)?)?;
        Ok(Self { pty, filter: Filter::default(), reset_parser: vte::Parser::new(),
            chrome: Chrome::default(), status: ProgramStatuses::default(), shell: Shell::default(), control: Control::default(),
            exited: false, error: None, audit_after: 0, report_counts: json!(null), event_id,
            input: VecDeque::new(), output: VecDeque::new(), delivery: Vec::new(), sequence: 0, program_reports: true })
    }
    pub fn queue(&mut self, bytes: &[u8]) -> Result<(), String> {
        if self.exited { return Err("shell has exited".into()); }
        if self.input.len() + bytes.len() > QUEUE { return Err("PTY input queue is full".into()); }
        self.input.extend(bytes); Ok(())
    }
    pub fn human_input(&mut self, bytes: &[u8]) -> Result<(), String> {
        if bytes.len() > 65548 { return Err("input exceeds 64 KiB plus paste delimiters".into()); }
        let dirty = self.control.dirty;
        self.control.human_input()?;
        let result = self.queue(bytes);
        if bytes.is_empty() || result.is_err() { self.control.dirty = dirty; }
        result
    }
    pub fn ready(&self) -> Result<(), String> {
        if self.exited || !self.shell.ready || self.control.dirty || !self.input.is_empty() || self.pty.input_pending() { return Err("an unedited integrated shell prompt is required".into()); }
        Ok(())
    }
    pub fn dispatch(&mut self, lease: u64, grant: u64, command: &str) -> Result<Value, String> {
        self.control.consume(lease, grant, command, &self.shell.cwd)?;
        if let Err(error) = self.ready().and_then(|_| self.queue(format!("{command}\r").as_bytes())) {
            self.control.dispatch_failed(); return Err(error);
        }
        self.shell.ready = false; self.control.dirty = true;
        Ok(json!({"accepted":true,"after_command_id":self.shell.summary()["last_command_id"],"completion_untrusted":true,"input_remains_leased":true}))
    }
    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), String> { self.pty.resize(size(cols, rows)?) }
    pub fn close(&mut self) -> Result<(), String> {
        self.exited = true; self.shell.finish(); self.status.finish_work(); self.pty.close()
    }
    fn feed(&mut self, bytes: &[u8]) -> Result<(), String> {
        for segment in self.filter.feed(bytes) {
            match segment {
                Segment::Pass(data) => {
                    let mut reset = Reset(false); self.reset_parser.advance(&mut reset, &data);
                    if reset.0 { self.status.clear(); }
                    self.shell.output(&data); self.output.extend(data);
                }
                Segment::Shell(body) => {
                    self.shell.observe(&body);
                    if body == b"133;A" { self.control.dirty = false; self.status.finish_work(); }
                    if body.starts_with(b"133;D") { self.control.observed_completion(); }
                }
                Segment::Document(body) => if self.program_reports { let _ = self.chrome.apply_bytes(&body); },
                Segment::ProgramStatus(body) => if self.program_reports {
                    if body == b"?" { self.queue(program_status::REPLY)?; } else { self.status.apply(&body); }
                },
            }
        }
        Ok(())
    }
    /// One bounded, nonblocking turn. Backpressure stops PTY reads until the UI acknowledges output.
    pub fn step(&mut self) -> Result<(), String> {
        if self.exited {
            if self.pty.exit_code().is_none() { self.pty.poll_exit()?; }
            return Ok(());
        }
        if !self.input.is_empty() {
            let count = self.pty.write(self.input.as_slices().0)?;
            self.input.drain(..count);
        }
        if self.output.len() + self.delivery.len() < QUEUE - 131072 {
            let mut buffer = [0u8; 8192];
            if let Some(count) = self.pty.read(&mut buffer)? {
                if count == 0 { self.exited = true; } else { self.feed(&buffer[..count])?; }
            }
        }
        self.pty.poll_exit()?;
        if self.exited { self.shell.finish(); self.status.finish_work(); }
        Ok(())
    }
    pub fn snapshot(&mut self, ack: u64) -> Result<Value, String> {
        if ack > self.sequence { return Err("invalid output acknowledgement".into()); }
        if ack == self.sequence { self.delivery.clear(); }
        if self.delivery.is_empty() && !self.output.is_empty() {
            self.delivery.extend(self.output.drain(..self.output.len().min(65536))); self.sequence += 1;
        }
        // Keep a 16-pane dashboard response below the bridge's 8 MiB bound. Full reports remain
        // in the bounded host state; only dashboard message presentation is shortened.
        let mut reports = self.status.to_json();
        for record in reports["records"].as_array_mut().into_iter().flatten() {
            if let Some(message) = record["msg"].as_str() && message.chars().count() > 128 {
                record["msg"] = json!(message.chars().take(128).collect::<String>());
                record["message_truncated"] = json!(true);
            }
        }
        Ok(json!({"sequence":self.sequence,"output":base64::engine::general_purpose::STANDARD.encode(&self.delivery),
            "control":self.control.summary(),"shell":self.shell.summary(),"program_status":reports,
            "chrome":self.chrome.to_json(now_ms()),"exited":self.exited,"exit_code":self.pty.exit_code(),"error":self.error,"event_session":self.event_id}))
    }
    pub fn counts(&self) -> Value {
        let mut counts = serde_json::Map::new();
        for record in self.status.to_json()["records"].as_array().into_iter().flatten() {
            if let Some(state) = record["state"].as_str() {
                let n = counts.get(state).and_then(Value::as_u64).unwrap_or(0); counts.insert(state.into(), json!(n + 1));
            }
        }
        Value::Object(counts)
    }
}

// Observe only hard resets; the host never owns a second terminal grid.
struct Reset(bool);
impl vte::Perform for Reset {
    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
        if !ignore && intermediates.is_empty() && byte == b'c' { self.0 = true; }
    }
}

/// Renderer replies cannot become a second arbitrary-input route while an agent owns the PTY.
pub(crate) fn terminal_reply(text: &str) -> bool {
    if text.is_empty() || text.len() > 4096 { return false; }
    let mut bytes = text.as_bytes();
    while !bytes.is_empty() {
        if bytes.starts_with(b"\x1b]") {
            let Some(end) = bytes.windows(2).position(|p| p == b"\x1b\\") else { return false };
            let Ok(body) = std::str::from_utf8(&bytes[2..end]) else { return false };
            let Some((code, color)) = body.split_once(";rgb:") else { return false };
            if !["10", "11", "12"].contains(&code) || color.split('/').count() != 3
                || !color.split('/').all(|part| !part.is_empty() && part.len() <= 4 && part.bytes().all(|b| b.is_ascii_hexdigit())) { return false; }
            bytes = &bytes[end + 2..]; continue;
        }
        if !bytes.starts_with(b"\x1b[") { return false; }
        let Some(end) = bytes[2..].iter().position(|b| (0x40..=0x7e).contains(b)).map(|n| n + 2) else { return false };
        if !matches!(bytes[end], b'R' | b'c' | b'n' | b'y' | b'u' | b't') || !bytes[2..end].iter().all(|b| b.is_ascii_digit() || b";?><!$".contains(b)) { return false; }
        bytes = &bytes[end + 1..];
    }
    true
}
