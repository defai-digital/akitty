use super::*;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::os::unix::fs::PermissionsExt;

struct Fixture { host: Arc<Host>, root: PathBuf, pane: String }
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("akitty-linux-test-{}", identifier().unwrap()));
        std::fs::create_dir(&root).unwrap(); std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let integration = root.join("integration"); std::fs::create_dir(&integration).unwrap();
        let hooks = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../macos/Sources/AkittyKit/Resources/shell-integration/akitty.bash").canonicalize().unwrap();
        std::fs::write(integration.join("bashrc"), format!("PS1='test> '\nsource '{}'\n", hooks.display())).unwrap();
        let host = Arc::new(Host::new(&root.join("events"), &integration).unwrap());
        let pane = host.action(Action::Create { shell: "/bin/bash".into(), cwd: root.to_string_lossy().into(), }).unwrap()["pane"].as_str().unwrap().to_owned();
        host.action(Action::Enable { enabled: true }).unwrap();
        let fixture = Self { host, root, pane }; fixture.wait_ready(); fixture
    }
    fn wait_ready(&self) { wait(|| self.host.state.lock().unwrap().panes[&self.pane].shell.ready); }
    fn request(&self, command: String) -> (UnixStream, mpsc::Receiver<Result<Value, String>>, String) {
        self.host.state.lock().unwrap().cooldown = Instant::now();
        let (client, peer) = UnixStream::pair().unwrap();
        let response = self.host.request(self.pane.clone(), command, 123, peer).unwrap();
        let id = self.host.state.lock().unwrap().pending.as_ref().unwrap().id.clone();
        (client, response, id)
    }
    fn marker_command(&self) -> String { format!("printf accepted >> '{}'", self.root.join("effect").display()) }
}
impl Drop for Fixture {
    fn drop(&mut self) { self.host.shutdown(); let _ = std::fs::remove_dir_all(&self.root); }
}
fn wait(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now()+Duration::from_secs(8);
    while !condition() { assert!(Instant::now() < deadline, "timed out waiting for PTY condition"); thread::sleep(Duration::from_millis(20)); }
}

#[test]
fn approved_real_pty_command_runs_once_retains_ownership_and_records_only_fingerprint() {
    let f = Fixture::new();
    let command = f.marker_command();
    let (_client, response, request) = f.request(command.clone());
    assert!(f.host.action(Action::Input { pane: f.pane.clone(), text: "oops".into() }).is_err());
    f.host.action(Action::Decide { request: request.clone(), allow: true }).unwrap();
    assert_eq!(response.recv_timeout(Duration::from_secs(2)).unwrap().unwrap()["accepted"], true);
    wait(|| std::fs::read_to_string(f.root.join("effect")).is_ok_and(|s| s == "accepted")); f.wait_ready();
    assert!(f.host.action(Action::Decide { request, allow: true }).is_err());
    assert!(f.host.action(Action::Input { pane: f.pane.clone(), text: "x".into() }).is_err());
    let events = f.host.action(Action::Export {}).unwrap()["jsonl"].as_str().unwrap().to_owned();
    assert!(events.contains("command_sha256")); assert!(events.contains("dispatched")); assert!(!events.contains(&command)); assert!(!events.contains("printf accepted"));
    f.host.action(Action::Reclaim { pane: f.pane.clone() }).unwrap();
    f.host.action(Action::Input { pane: f.pane.clone(), text: String::new() }).unwrap();
    assert_eq!(std::fs::read_to_string(f.root.join("effect")).unwrap(), "accepted");
}

#[test]
fn denial_disconnect_timeout_disable_and_reclaim_never_dispatch() {
    let f = Fixture::new();
    for mode in ["deny", "disconnect", "timeout", "disable", "reclaim"] {
        let (client, response, id) = f.request(f.marker_command());
        match mode {
            "deny" => { f.host.action(Action::Decide { request: id.clone(), allow: false }).unwrap(); }
            "disconnect" => { drop(client); }
            "timeout" => { f.host.state.lock().unwrap().pending.as_mut().unwrap().deadline = Instant::now(); }
            "disable" => { f.host.action(Action::Enable { enabled: false }).unwrap(); }
            "reclaim" => { f.host.action(Action::Reclaim { pane: f.pane.clone() }).unwrap(); }
            _ => unreachable!(),
        }
        assert!(response.recv_timeout(Duration::from_secs(2)).unwrap().is_err(), "{mode}");
        assert!(f.host.action(Action::Decide { request: id, allow: true }).is_err());
        assert!(!f.root.join("effect").exists());
        f.host.action(Action::Enable { enabled: true }).unwrap();
    }
}

#[test]
fn changed_context_dirty_prompt_and_recording_failure_reject_approval() {
    for mode in ["directory", "dirty", "storage"] {
        let f = Fixture::new();
        let (_client, response, id) = f.request(f.marker_command());
        {
            let mut state = f.host.state.lock().unwrap();
            match mode {
                "directory" => state.panes.get_mut(&f.pane).unwrap().shell.cwd = Some("/".into()),
                "dirty" => state.panes.get_mut(&f.pane).unwrap().control.dirty = true,
                "storage" => std::fs::set_permissions(f.root.join("events/events.jsonl"), std::fs::Permissions::from_mode(0o644)).unwrap(),
                _ => unreachable!(),
            }
        }
        assert!(f.host.action(Action::Decide { request: id, allow: true }).is_err(), "{mode}");
        assert!(response.recv_timeout(Duration::from_secs(2)).unwrap().is_err());
        assert!(!f.root.join("effect").exists());
        if mode == "storage" { assert!(f.host.action(Action::Enable { enabled: true }).is_err()); }
    }
}

#[test]
fn recording_failure_after_dispatch_reports_uncertainty_without_retry_or_releasing_control() {
    let f = Fixture::new();
    let (_client, response, id) = f.request(f.marker_command());
    {
        let mut state = f.host.state.lock().unwrap();
        state.store.fail_after = Some(1); // Persist authorization, fail when recording dispatch.
        let error = state.decide(&id, true).unwrap_err();
        assert!(error.contains("uncertain"), "{error}");
        assert!(state.failure.is_some());
    }
    assert!(response.recv_timeout(Duration::from_secs(2)).unwrap().unwrap_err().contains("uncertain"));
    wait(|| f.root.join("effect").exists()); f.wait_ready();
    assert_eq!(std::fs::read_to_string(f.root.join("effect")).unwrap(), "accepted");
    assert!(f.host.action(Action::Input { pane: f.pane.clone(), text: "x".into() }).is_err());
    assert!(f.host.action(Action::Decide { request: id, allow: true }).is_err());
    f.host.action(Action::Reclaim { pane: f.pane.clone() }).unwrap();
    assert_eq!(f.host.state.lock().unwrap().panes[&f.pane].control.summary()["owner"], "human");
}

#[test]
fn malformed_commands_and_renderer_responses_cannot_bypass_authority() {
    for command in ["", " \t", "echo a\necho b", "echo\u{202e}bad", "echo\u{200b}bad"] { assert!(validate_command(command).is_err()); }
    assert!(validate_command(&"a".repeat(4097)).is_err());
    assert!(validate_command("echo 'hello'; echo world").is_ok());
    for text in ["echo bad\r", "\x1b[1;2Recho bad\r", "\x1b]52;c;bad\x07", "\x1b[200~x\x1b[201~"] { assert!(!session::terminal_reply(text)); }
    assert!(session::terminal_reply("\x1b[1;2R\x1b[?1;2c"));
    assert!(serde_json::from_value::<Action>(json!({"op":"decide","request":"x","allow":true,"command":"other"})).is_err());
}

#[test]
fn output_replays_until_acknowledged_and_agent_reports_never_grant_control() {
    let f = Fixture::new();
    f.host.action(Action::Input { pane: f.pane.clone(), text: "printf '\\033]7501;state=done:app=test\\007VISIBLE\\n'\r".into() }).unwrap();
    wait(|| f.host.state.lock().unwrap().panes[&f.pane].counts()["done"] == 1);
    let first = f.host.action(Action::Poll { acknowledgements: BTreeMap::new() }).unwrap();
    let replay = f.host.action(Action::Poll { acknowledgements: BTreeMap::new() }).unwrap();
    assert_eq!(first["panes"][&f.pane]["sequence"], replay["panes"][&f.pane]["sequence"]);
    assert_eq!(first["panes"][&f.pane]["output"], replay["panes"][&f.pane]["output"]);
    assert_eq!(replay["panes"][&f.pane]["control"]["owner"], "human");
    assert!(f.host.action(Action::Poll { acknowledgements: BTreeMap::from([(f.pane.clone(), u64::MAX)]) }).is_err());
}

#[test]
fn bounded_store_rotates_recovers_incomplete_tail_and_rejects_symlinks() {
    let root = std::env::temp_dir().join(format!("akitty-store-{}", identifier().unwrap()));
    {
        let mut store = Store::with_limit(&root, 32768).unwrap();
        assert!(Store::new(&root).is_err());
        for _ in 0..100 { store.append("test", "session", "host", json!({"bounded":"x".repeat(1000)})).unwrap(); }
        let text = store.export().unwrap(); assert!(text.len() <= 65536); assert!(text.contains("retention_rotated"));
        for line in text.lines() { serde_json::from_str::<Value>(line).unwrap(); }
    }
    std::fs::OpenOptions::new().append(true).open(root.join("events.jsonl")).unwrap().write_all(b"unfinished").unwrap();
    {
        let store = Store::with_limit(&root, 32768).unwrap();
        assert!(store.export().unwrap().contains("incomplete_record_dropped"));
    }
    std::fs::remove_file(root.join("events.jsonl")).unwrap();
    std::os::unix::fs::symlink("previous.jsonl", root.join("events.jsonl")).unwrap();
    assert!(Store::new(&root).is_err()); std::fs::remove_dir_all(root).unwrap();
}

#[cfg(target_os = "linux")]
#[test]
fn linux_same_user_ipc_is_request_only_and_dispatches_after_ui_approval() {
    let f = Fixture::new(); let path = f.root.join("ipc/requests.sock");
    let server = ipc::Server::start(&f.host, &path).unwrap();
    assert!(ipc::Server::start(&f.host, &path).is_err());
    let list = ipc::call(&path, &json!({"op":"list","version":1})).unwrap(); assert_eq!(list["data"]["panes"][0]["pane"], f.pane);
    for request in [json!({"op":"list","version":true}),json!({"op":"list","version":1,"extra":true}),json!({"op":"command_authorize","version":1}),json!({"op":"list","version":1,"offset":65})] {
        // The serial server may still be finishing its previous response; wait until it accepts again.
        thread::sleep(Duration::from_millis(40));
        assert_eq!(ipc::call(&path, &request).unwrap()["ok"], false);
    }
    thread::sleep(Duration::from_millis(40));
    let request = json!({"op":"request","version":1,"pane":f.pane,"command":f.marker_command()}); let socket = path.clone();
    let caller = thread::spawn(move || ipc::call(&socket, &request).unwrap());
    wait(|| f.host.state.lock().unwrap().pending.is_some());
    let id = f.host.state.lock().unwrap().pending.as_ref().unwrap().id.clone();
    assert!(!f.root.join("effect").exists());
    f.host.action(Action::Decide { request: id, allow: true }).unwrap(); assert_eq!(caller.join().unwrap()["ok"], true);
    wait(|| f.root.join("effect").exists()); drop(server);
}
