//! Experimental desktop trusted host. Only the local UI can resolve pending approvals.
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg_attr(windows, path = "windows/ipc.rs")]
pub mod ipc;
mod platform;
#[cfg(windows)]
mod windows;
mod session;
#[cfg_attr(windows, path = "windows/store.rs")]
mod store;

use serde::Deserialize;
use serde_json::{Value, json};
use session::Session;
use std::collections::BTreeMap;
use ipc::Peer;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use store::{Store, digest, identifier};

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Action {
    Environment {},
    Quit {},
    Create { shell: String, cwd: String },
    Poll { acknowledgements: BTreeMap<String, u64> },
    Input { pane: String, text: String },
    Reply { pane: String, text: String },
    Resize { pane: String, cols: u16, rows: u16 },
    Close { pane: String },
    Reclaim { pane: String },
    Enable { enabled: bool },
    Decide { request: String, allow: bool },
    Reports { pane: String, enabled: bool },
    History { pane: String, after: u64 },
    Output { pane: String, command: u64 },
    Export {},
    ExportTo { path: String },
}
struct Pending {
    id: String, pane: String, command: String, cwd: Option<String>, lease: u64,
    pid: u32, deadline: Instant, peer: Peer, response: mpsc::Sender<Result<Value, String>>,
}
struct State {
    panes: BTreeMap<String, Session>, pending: Option<Pending>, store: Store,
    failure: Option<String>, enabled: bool, cooldown: Instant, integration: PathBuf,
}
pub struct Host { state: Arc<Mutex<State>>, stop: Arc<AtomicBool>, worker: Mutex<Option<JoinHandle<()>>> }

impl Host {
    pub fn new(events: &Path, integration: &Path) -> Result<Self, String> {
        let state = Arc::new(Mutex::new(State { panes: BTreeMap::new(), pending: None, store: Store::new(events)?,
            failure: None, enabled: false, cooldown: Instant::now(), integration: integration.to_path_buf() }));
        let stop = Arc::new(AtomicBool::new(false));
        let worker_state = state.clone(); let worker_stop = stop.clone();
        let worker = thread::Builder::new().name("akitty-desktop-pty".into()).spawn(move || {
            while !worker_stop.load(Ordering::SeqCst) {
                if let Ok(mut state) = worker_state.lock() {
                    for pane in state.panes.values_mut() {
                        if let Err(error) = pane.step() { pane.error = Some(error); let _ = pane.close(); }
                    }
                    state.expire(); state.collect();
                } else { break; }
                thread::sleep(Duration::from_millis(10));
            }
            if let Ok(mut state) = worker_state.lock() {
                state.cancel("application is closing");
                let mut closed = Vec::new();
                for pane in state.panes.values_mut() { closed.push((pane.event_id.clone(), pane.close().is_ok())); }
                state.collect();
                for (session, clean) in closed { state.record("session_closed", &session, "host", json!({"cleanup_complete":clean})); }
            }
        }).map_err(|e| e.to_string())?;
        Ok(Self { state, stop, worker: Mutex::new(Some(worker)) })
    }
    pub fn action(&self, action: Action) -> Result<Value, String> {
        let mut state = self.state.lock().map_err(|_| "host unavailable")?;
        state.expire();
        let result = match action {
            Action::Environment {} => environment(),
            Action::Quit {} => Err("quit is a desktop lifecycle operation".into()),
            Action::Create { shell, cwd } => {
                if state.panes.len() >= 16 { return Err("experimental host supports at most 16 terminals".into()); }
                let id = identifier()?;
                let pane = Session::new(&shell, Path::new(&cwd), &state.integration, identifier()?)?;
                state.record("session_opened", &pane.event_id, "host", json!({}));
                state.panes.insert(id.clone(), pane); Ok(json!({"pane":id}))
            }
            Action::Poll { acknowledgements } => {
                if acknowledgements.len() > 16 { return Err("too many acknowledgements".into()); }
                let mut panes = serde_json::Map::new();
                for (id, pane) in &mut state.panes { panes.insert(id.clone(), pane.snapshot(*acknowledgements.get(id).unwrap_or(&0))?); }
                let pending = state.pending.as_ref().map(|p| json!({"id":p.id,"pane":p.pane,"command":p.command,"cwd_untrusted":p.cwd,"pid":p.pid}));
                Ok(json!({"panes":panes,"pending":pending,"enabled":state.enabled,"recording_error":state.failure,"experimental":true}))
            }
            Action::Input { pane, text } => state.pane(&pane)?.human_input(text.as_bytes()).map(|_| json!({})),
            Action::Reply { pane, text } => {
                if !session::terminal_reply(&text) { return Err("unsupported terminal response".into()); }
                state.pane(&pane)?.queue(text.as_bytes()).map(|_| json!({}))
            }
            Action::Resize { pane, cols, rows } => state.pane(&pane)?.resize(cols, rows).map(|_| json!({})),
            Action::Close { pane } => {
                if state.pending.as_ref().is_some_and(|p| p.pane == pane) { state.cancel("target terminal closed"); }
                state.collect();
                let mut session = state.panes.remove(&pane).ok_or("unknown terminal")?;
                let result = session.close(); state.record("session_closed", &session.event_id, "host", json!({}));
                result.map(|_| json!({}))
            }
            Action::Reclaim { pane } => {
                if state.pending.as_ref().is_some_and(|p| p.pane == pane) { state.cancel("human reclaimed terminal"); }
                state.pane(&pane)?.control.release(None)
            }
            Action::Enable { enabled } => {
                if enabled { state.healthy()?; }
                state.enabled = enabled;
                if !enabled { state.cancel("local agent requests disabled"); }
                Ok(json!({}))
            }
            Action::Decide { request, allow } => state.decide(&request, allow),
            Action::Reports { pane, enabled } => { state.pane(&pane)?.program_reports = enabled; Ok(json!({})) }
            Action::History { pane, after } => Ok(state.pane(&pane)?.shell.history(after)),
            Action::Output { pane, command } => state.pane(&pane)?.shell.command_output(command),
            // The UI previews a bounded tail; full retained JSONL goes directly to a private file.
            // Sending two full segments as escaped JSON could exceed the bridge response bound.
            Action::Export {} => state.store.export().map(|text| {
                let lines: Vec<_> = text.lines().rev().take(200).collect();
                json!({"jsonl":lines.into_iter().rev().collect::<Vec<_>>().join("\n"),"preview_only":true})
            }),
            Action::ExportTo { path } => {
                if path.len() > 4096 || !Path::new(&path).is_absolute() { return Err("export path must be absolute and bounded".into()); }
                store::export_to(Path::new(&path), &state.store.export()?)?;
                Ok(json!({"path":path}))
            }
        };
        state.collect(); result
    }
    pub fn shutdown(&self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Ok(mut worker) = self.worker.lock() && let Some(worker) = worker.take() { let _ = worker.join(); }
    }
    pub(crate) fn transport_failed(&self, error: String) {
        if let Ok(mut state) = self.state.lock() {
            state.enabled = false; state.cancel("local agent service failed");
            state.failure = Some(format!("local agent service failed: {error}"));
        }
    }
    pub(crate) fn list(&self, offset: usize) -> Result<Value, String> {
        let state = self.state.lock().map_err(|_| "host unavailable")?;
        if !state.enabled { return Err("local agent requests are disabled".into()); }
        if offset > 64 { return Err("invalid list offset".into()); }
        let panes: Vec<Value> = state.panes.iter().skip(offset).take(16).map(|(id, p)| json!({"pane":id,"event_session":p.event_id,
            "input_agent_controlled":p.control.summary()["agent"],"execution":"request_requires_human_approval","ordinary_agent_operations":"observation_only"})).collect();
        Ok(json!({"panes":panes,"next_offset":null,"total_panes":state.panes.len()}))
    }
    pub(crate) fn request(&self, pane: String, command: String, pid: u32, peer: Peer) -> Result<mpsc::Receiver<Result<Value, String>>, String> {
        validate_command(&command)?;
        let mut state = self.state.lock().map_err(|_| "host unavailable")?;
        state.expire(); state.healthy()?;
        if !state.enabled || state.pending.is_some() || Instant::now() < state.cooldown { return Err("local requests are disabled, busy or cooling down".into()); }
        if !ipc::connected(&peer) { return Err("requester disconnected".into()); }
        let request_id = identifier()?;
        let target = state.pane(&pane)?; target.ready()?;
        let event_id = target.event_id.clone();
        state.record("execution_requested", &event_id, "host", digest(&command)); state.healthy()?;
        let target = state.pane(&pane)?;
        let lease = target.control.acquire(format!("local process {pid}"))?["lease"].as_u64().ok_or("missing lease")?;
        let cwd = target.shell.cwd.clone();
        let (response, receiver) = mpsc::channel();
        state.pending = Some(Pending { id: request_id, pane, command, cwd, lease, pid, deadline: Instant::now()+Duration::from_secs(120), peer, response });
        state.collect(); Ok(receiver)
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        self.shutdown();
    }
}
impl State {
    fn pane(&mut self, id: &str) -> Result<&mut Session, String> { self.panes.get_mut(id).ok_or_else(|| "unknown or closed terminal".into()) }
    fn healthy(&self) -> Result<(), String> { self.failure.as_ref().map_or(Ok(()), |e| Err(format!("managed requests unavailable; restore the failed service or storage and restart: {e}"))) }
    fn record(&mut self, event: &str, session: &str, source: &str, fields: Value) {
        if self.failure.is_none() && let Err(error) = self.store.append(event, session, source, fields) { self.failure = Some(error); }
    }
    fn collect(&mut self) {
        let mut records: Vec<(String, String, &str, Value)> = Vec::new();
        for pane in self.panes.values_mut() {
            let page = pane.control.audit(pane.audit_after);
            if page["oldest_seq"].as_u64().is_some_and(|n| n > pane.audit_after + 1) {
                records.push(("source_gap".into(),pane.event_id.clone(),"host",json!({"after":pane.audit_after,"oldest_available":page["oldest_seq"]})));
            }
            for event in page["events"].as_array().into_iter().flatten() {
                let mut fields = json!({"core_sequence":event["seq"],"observed_time_ms":event["time_ms"],"host_actor_label":event["actor"]});
                if let Some(command) = event["command"].as_str() { fields.as_object_mut().unwrap().extend(digest(command).as_object().unwrap().clone()); }
                let name = event["event"].as_str().unwrap_or("unknown");
                records.push((name.into(),pane.event_id.clone(),if name.contains("untrusted") {"shell_untrusted"} else {"host"},fields));
                pane.audit_after = event["seq"].as_u64().unwrap_or(pane.audit_after);
            }
            let counts = pane.counts();
            if pane.report_counts != counts { records.push(("program_status_observed".into(),pane.event_id.clone(),"program_untrusted",json!({"state_counts":counts}))); pane.report_counts = counts; }
        }
        for (event, session, source, fields) in records { self.record(&event, &session, source, fields); }
    }
    fn cancel(&mut self, reason: &str) {
        if let Some(p) = self.pending.take() {
            if let Some(target) = self.panes.get_mut(&p.pane) { let _ = target.control.deny(p.lease); let _ = target.control.release(Some(p.lease)); }
            let _ = p.response.send(Err(reason.into())); self.cooldown = Instant::now()+Duration::from_secs(3);
        }
    }
    fn expire(&mut self) {
        if self.pending.as_ref().is_some_and(|p| Instant::now() >= p.deadline || !ipc::connected(&p.peer)) { self.cancel("approval expired or requester disconnected"); }
    }
    fn decide(&mut self, id: &str, allow: bool) -> Result<Value, String> {
        if !self.pending.as_ref().is_some_and(|p| p.id == id) { return Err("stale approval request".into()); }
        if !allow { self.cancel("command denied"); return Ok(json!({})); }
        if let Err(error) = self.healthy() { self.cancel("event recording failed"); return Err(error); }
        let p = self.pending.take().ok_or("stale approval request")?;
        self.cooldown = Instant::now()+Duration::from_secs(3);
        let mut attempted = false;
        let result = (|| {
            if !self.enabled || Instant::now() >= p.deadline || !ipc::connected(&p.peer) { return Err("approval expired or requester disconnected".into()); }
            let target = self.pane(&p.pane)?; target.ready()?;
            if target.shell.cwd != p.cwd { return Err("working directory changed since approval request".into()); }
            let grant = target.control.authorize(p.lease, p.command.clone(), p.cwd.clone())?["authorization"].as_u64().ok_or("missing authorization")?;
            // Persist authority before dispatch. A storage failure never permits a new managed command.
            self.collect(); self.healthy()?;
            if !ipc::connected(&p.peer) { return Err("requester disconnected".into()); }
            attempted = true;
            let receipt = self.pane(&p.pane)?.dispatch(p.lease, grant, &p.command)?;
            self.collect(); self.healthy().map_err(|_| "command dispatch outcome is uncertain after recording failure; inspect and reclaim; do not retry".to_string())?;
            Ok(receipt)
        })();
        if result.is_err() && !attempted && let Some(target) = self.panes.get_mut(&p.pane) { let _ = target.control.release(Some(p.lease)); }
        let _ = p.response.send(result.clone()); result
    }
}

pub fn validate_command(command: &str) -> Result<(), String> {
    // Reject Unicode format controls in addition to C0/C1, matching the native trusted host.
    let format = |c: char| unicode_general_category::get_general_category(c) == unicode_general_category::GeneralCategory::Format;
    if command.trim().is_empty() || command.len() > 4096 || command.chars().any(|c| c.is_control() || format(c)) { return Err("command must be one line of at most 4096 UTF-8 bytes without control or format characters".into()); }
    Ok(())
}

#[cfg(all(test, unix))]
mod tests;
#[cfg(all(test, windows))]
#[path = "windows/tests.rs"]
mod tests;

fn environment() -> Result<Value, String> {
    #[cfg(unix)]
    let (home, shells, platform) = (std::env::var("HOME").unwrap_or_else(|_| "/".into()),
        ["/bin/bash", "/bin/zsh", "/usr/bin/zsh"].into_iter().filter(|p| Path::new(p).is_file()).map(str::to_owned).collect::<Vec<_>>(), "Linux");
    #[cfg(windows)]
    let (home, shells, platform) = (std::env::var("USERPROFILE").map_err(|_| "USERPROFILE is required")?, windows::shells(), "Windows");
    Ok(json!({"home":home,"shells":shells,"platform":platform,"socket":ipc::default_socket()?.to_string_lossy()}))
}
