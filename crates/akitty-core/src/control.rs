//! Trusted host control. Terminal output never calls these methods.
use crate::chrome::now_ms;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

#[derive(Serialize)]
struct Audit {
    seq: u64,
    time_ms: u64,
    event: String,
    actor: String,
    command: Option<String>,
}
struct Grant {
    id: u64,
    command: String,
    cwd: Option<String>,
    expires: Instant,
}
#[derive(Default)]
pub struct Control {
    lease: Option<(u64, String)>,
    grant: Option<Grant>,
    next: u64,
    seq: u64,
    events: VecDeque<Audit>,
    /// Human input after a prompt means that injecting another command could execute an edited line.
    pub dirty: bool,
    awaiting_completion: bool,
}
impl Control {
    fn identifier(&mut self) -> Result<u64, String> {
        self.next = self.next.checked_add(1).ok_or("control identifier exhausted")?; Ok(self.next)
    }
    pub fn record(&mut self, event: &str, command: Option<String>) {
        self.seq = self.seq.saturating_add(1);
        if self.events.len() == 64 { self.events.pop_front(); }
        self.events.push_back(Audit { seq: self.seq, time_ms: now_ms(), event: event.into(),
            actor: self.lease.as_ref().map(|l|l.1.clone()).unwrap_or_else(||"human".into()), command });
    }
    pub fn acquire(&mut self, actor: String) -> Result<Value, String> {
        if actor.is_empty() || actor.len() > 64 || actor.chars().any(|c|c.is_control()) { return Err("actor must be 1..64 bytes without controls".into()); }
        if self.lease.is_some() { return Err("terminal already has an agent controller".into()); }
        let id = self.identifier()?;
        self.lease = Some((id, actor)); self.grant = None;
        self.record("acquired",None); Ok(json!({"lease":id}))
    }
    fn check(&self, lease: u64) -> Result<(), String> {
        if self.lease.as_ref().is_some_and(|l|l.0==lease) { Ok(()) } else { Err("stale or invalid control lease".into()) }
    }
    pub fn human_input(&mut self) -> Result<(), String> {
        if self.lease.is_some() { self.record("human_input_blocked",None); return Err("agent controls this terminal; reclaim control before typing".into()); }
        self.dirty = true; Ok(())
    }
    pub fn release(&mut self, lease: Option<u64>) -> Result<Value, String> {
        if let Some(lease) = lease { self.check(lease)?; }
        self.record(if lease.is_some() {"released"} else {"human_reclaimed"},None);
        self.lease = None; self.grant = None; Ok(json!({}))
    }
    pub fn authorize(&mut self, lease: u64, command: String, cwd: Option<String>) -> Result<Value, String> {
        self.check(lease)?;
        if command.trim().is_empty() || command.len() > 4096 || command.chars().any(|c|c.is_control()) {
            self.record("authorization_rejected",None); return Err("command must be 1..4096 bytes on one line without controls".into());
        }
        let id = self.identifier()?;
        self.record("authorized",Some(command.clone()));
        self.grant = Some(Grant { id, command, cwd, expires: Instant::now()+Duration::from_secs(30) });
        Ok(json!({"authorization":id,"expires_in_ms":30000}))
    }
    pub fn deny(&mut self, lease: u64) -> Result<Value, String> {
        self.check(lease)?; self.grant = None; self.record("denied",None); Ok(json!({}))
    }
    pub fn consume(&mut self, lease: u64, authorization: u64, command: &str, cwd: &Option<String>) -> Result<(), String> {
        self.check(lease)?;
        let grant = self.grant.take().ok_or("command requires a fresh host authorization")?;
        if grant.id != authorization || grant.command != command || &grant.cwd != cwd || Instant::now() >= grant.expires {
            self.record("authorization_rejected",None); return Err("authorization expired or does not match command and working directory".into());
        }
        self.record("dispatched",Some(command.into())); self.awaiting_completion = true; Ok(())
    }
    pub fn observed_completion(&mut self) {
        if self.awaiting_completion {
            self.record("shell_completion_observed_untrusted",None); self.awaiting_completion = false;
        }
    }
    pub fn summary(&self) -> Value {
        json!({"owner":self.lease.as_ref().map(|l|l.1.as_str()).unwrap_or("human"),"agent":self.lease.is_some(),"audit_seq":self.seq})
    }
    pub fn audit(&self, after: u64) -> Value {
        json!({"events":self.events.iter().filter(|e|e.seq>after).collect::<Vec<_>>(),"oldest_seq":self.events.front().map(|e|e.seq),"last_seq":self.seq})
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn grants_are_exact_once_expiring_and_revoked_on_reclaim() {
        let mut control = Control::default();
        let lease = control.acquire("agent".into()).unwrap()["lease"].as_u64().unwrap();
        let cwd = Some("/tmp".into());
        let grant = control.authorize(lease,"echo hi".into(),cwd.clone()).unwrap()["authorization"].as_u64().unwrap();
        assert!(control.human_input().is_err());
        assert!(control.consume(lease,grant,"echo nope",&cwd).is_err());
        assert!(control.consume(lease,grant,"echo hi",&cwd).is_err());
        let grant = control.authorize(lease,"echo hi".into(),cwd.clone()).unwrap()["authorization"].as_u64().unwrap();
        control.grant.as_mut().unwrap().expires = Instant::now()-Duration::from_secs(1);
        assert!(control.consume(lease,grant,"echo hi",&cwd).is_err());
        control.release(None).unwrap();
        assert!(control.authorize(lease,"echo hi".into(),cwd).is_err());
        assert!(control.human_input().is_ok());
    }
}
