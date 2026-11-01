use super::*;
use std::io::Write;

struct Fixture { host: Arc<Host>, server: Option<ipc::Server>, root: PathBuf, pipe: PathBuf, pane: String }
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("akitty-windows-test-{}", identifier().unwrap()));
        std::fs::create_dir(&root).unwrap();
        let integration = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../windows/shell-integration").canonicalize().unwrap();
        let host = Arc::new(Host::new(&root.join("events"), &integration).unwrap());
        let shell = windows::shells().last().expect("Windows PowerShell is installed").clone();
        let pane = host.action(Action::Create { shell, cwd: root.to_string_lossy().into() }).unwrap()["pane"].as_str().unwrap().to_owned();
        let pipe = PathBuf::from(format!(r"\\.\pipe\AkiTTY-Experimental-test-{}", identifier().unwrap()));
        let server = ipc::Server::start(&host, &pipe).unwrap();
        let fixture = Self { host, server: Some(server), root, pipe, pane }; fixture.wait_ready(); fixture
    }
    fn wait_ready(&self) { wait(|| self.host.state.lock().unwrap().panes[&self.pane].shell.ready); }
    fn command(&self) -> String { format!("[IO.File]::AppendAllText('{}','accepted')", self.root.join("effect").display()) }
    fn begin(&self) -> (std::fs::File, String) {
        self.host.action(Action::Enable { enabled: true }).unwrap();
        self.host.state.lock().unwrap().cooldown = Instant::now();
        let peer = ipc::begin_test(&self.pipe, &json!({"op":"request","version":1,"pane":self.pane,"command":self.command()})).unwrap();
        wait(|| self.host.state.lock().unwrap().pending.is_some());
        let id = self.host.state.lock().unwrap().pending.as_ref().unwrap().id.clone(); (peer, id)
    }
    fn settle(&self) { wait(|| self.host.state.lock().unwrap().pending.is_none()); thread::sleep(Duration::from_millis(80)); }
}
impl Drop for Fixture {
    fn drop(&mut self) { self.host.shutdown(); self.server.take(); let _ = std::fs::remove_dir_all(&self.root); }
}
fn wait(mut condition: impl FnMut() -> bool) {
    let end = Instant::now()+Duration::from_secs(25);
    while !condition() { assert!(Instant::now() < end, "timed out waiting for native Windows condition"); thread::sleep(Duration::from_millis(20)); }
}
#[test]
fn real_conpty_powershell_named_pipe_approval_once_reclaim_and_private_timeline() {
    let f = Fixture::new();
    assert_eq!(ipc::call(&f.pipe, &json!({"op":"list","version":1})).unwrap()["ok"], false);
    f.host.action(Action::Enable { enabled: true }).unwrap();
    assert_eq!(ipc::call(&f.pipe, &json!({"op":"list","version":1})).unwrap()["data"]["panes"][0]["pane"], f.pane);
    let pipe = f.pipe.clone(); let request = json!({"op":"request","version":1,"pane":f.pane,"command":f.command()});
    let caller = thread::spawn(move || ipc::call(&pipe, &request));
    wait(|| f.host.state.lock().unwrap().pending.is_some());
    let id = f.host.state.lock().unwrap().pending.as_ref().unwrap().id.clone();
    assert!(f.host.action(Action::Input { pane:f.pane.clone(), text:"oops".into() }).is_err());
    f.host.action(Action::Decide { request:id.clone(), allow:true }).unwrap();
    assert_eq!(caller.join().unwrap().unwrap()["ok"], true);
    wait(|| std::fs::read_to_string(f.root.join("effect")).is_ok_and(|s| s == "accepted")); f.wait_ready();
    assert!(f.host.action(Action::Decide { request:id, allow:true }).is_err());
    assert!(f.host.action(Action::Input { pane:f.pane.clone(), text:"x".into() }).is_err());
    f.host.action(Action::Reclaim { pane:f.pane.clone() }).unwrap();
    let text = f.host.action(Action::Export {}).unwrap()["jsonl"].as_str().unwrap().to_owned();
    assert!(text.contains("command_sha256")); assert!(!text.contains(&f.command()));
    let export = f.root.join("export.jsonl"); store::export_to(&export, &text).unwrap(); assert!(store::export_to(&export, &text).is_err());
    assert_eq!(std::fs::read_to_string(export).unwrap(), text);
}
#[test]
fn denial_disconnect_expiry_disable_and_reclaim_never_execute() {
    let f = Fixture::new();
    for mode in ["deny", "disconnect", "timeout", "disable", "reclaim"] {
        let (peer, id) = f.begin();
        match mode {
            "deny" => { f.host.action(Action::Decide { request:id.clone(), allow:false }).unwrap(); }
            "disconnect" => { drop(peer); f.settle(); continue; }
            "timeout" => f.host.state.lock().unwrap().pending.as_mut().unwrap().deadline = Instant::now(),
            "disable" => { f.host.action(Action::Enable { enabled:false }).unwrap(); }
            "reclaim" => { f.host.action(Action::Reclaim { pane:f.pane.clone() }).unwrap(); }
            _ => unreachable!(),
        }
        drop(peer); f.settle();
        assert!(f.host.action(Action::Decide { request:id, allow:true }).is_err());
        assert!(!f.root.join("effect").exists());
    }
    assert!(!f.root.join("effect").exists());
}
#[test]
fn stale_context_dirty_prompt_and_storage_failure_fail_closed() {
    for mode in ["directory", "dirty", "storage"] {
        let f = Fixture::new(); let (peer,id) = f.begin();
        {
            let mut state = f.host.state.lock().unwrap();
            match mode {
                "directory" => state.panes.get_mut(&f.pane).unwrap().shell.cwd = Some("/C:/other".into()),
                "dirty" => state.panes.get_mut(&f.pane).unwrap().control.dirty = true,
                "storage" => state.store.fail_after = Some(0),
                _ => unreachable!(),
            }
        }
        assert!(f.host.action(Action::Decide { request:id, allow:true }).is_err());
        drop(peer); f.settle(); assert!(!f.root.join("effect").exists());
    }
}
#[test]
fn post_dispatch_storage_failure_retains_lease_and_never_retries() {
    let f = Fixture::new(); let (peer,id) = f.begin();
    f.host.state.lock().unwrap().store.fail_after = Some(1);
    assert!(f.host.action(Action::Decide { request:id.clone(), allow:true }).unwrap_err().contains("uncertain"));
    wait(|| f.root.join("effect").exists()); f.wait_ready();
    assert!(f.host.action(Action::Decide { request:id, allow:true }).is_err());
    assert!(f.host.action(Action::Input { pane:f.pane.clone(), text:"x".into() }).is_err());
    f.host.action(Action::Reclaim { pane:f.pane.clone() }).unwrap();
    assert_eq!(std::fs::read_to_string(f.root.join("effect")).unwrap(),"accepted"); drop(peer);
}
#[test]
fn strict_requests_and_terminal_replies_cannot_bypass_authority() {
    let f=Fixture::new();
    assert!(ipc::Server::start(&f.host,&f.pipe).is_err());
    for request in [json!({"op":"list","version":true}),json!({"op":"list","version":1,"extra":true}),json!({"op":"command_authorize","version":1})] {
        assert_eq!(ipc::call(&f.pipe,&request).unwrap()["ok"], false);
    }
    assert!(ipc::call(Path::new(r"\\remote\pipe\AkiTTY-Experimental-test"),&json!({"op":"list","version":1})).is_err());
    for command in ["", "echo a\necho b", "echo\u{202e}bad"] { assert!(validate_command(command).is_err()); }
    for text in ["echo bad\r", "\x1b[1;2Recho bad\r", "\x1b]52;c;bad\x07"] { assert!(!session::terminal_reply(text)); }
}
#[test]
fn event_store_rotation_recovery_exclusive_lock_and_hardlink_rejection() {
    let root=std::env::temp_dir().join(format!("akitty-store-{}",identifier().unwrap()));
    {
        let mut store=Store::with_limit(&root,32768).unwrap(); assert!(Store::new(&root).is_err());
        for _ in 0..100 { store.append("test","session","host",json!({"bounded":"x".repeat(1000)})).unwrap(); }
        let text=store.export().unwrap(); assert!(text.len()<=65536); assert!(text.contains("retention_rotated"));
    }
    std::fs::OpenOptions::new().append(true).open(root.join("events.jsonl")).unwrap().write_all(b"unfinished").unwrap();
    { let store=Store::with_limit(&root,32768).unwrap(); assert!(store.export().unwrap().contains("incomplete_record_dropped")); }
    std::fs::hard_link(root.join("events.jsonl"),root.join("alias")).unwrap();
    assert!(Store::new(&root).is_err()); std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn conpty_resize_and_close_bound_process_tree_lifetime() {
    let f=Fixture::new();
    f.host.action(Action::Resize { pane:f.pane.clone(),cols:120,rows:40 }).unwrap();
    assert!(f.host.action(Action::Resize { pane:f.pane.clone(),cols:0,rows:40 }).is_err());
    let command=format!("Start-Process powershell.exe -ArgumentList '-NoProfile','-Command',\"Start-Sleep 4; [IO.File]::WriteAllText('{}','escaped')\"; Start-Sleep 30\r",f.root.join("escaped").display());
    f.host.action(Action::Input { pane:f.pane.clone(),text:command }).unwrap();
    wait(|| !f.host.state.lock().unwrap().panes[&f.pane].shell.ready);
    thread::sleep(Duration::from_millis(600));
    let start=Instant::now(); let _=f.host.action(Action::Close { pane:f.pane.clone() });
    assert!(start.elapsed()<Duration::from_secs(2));
    thread::sleep(Duration::from_secs(5)); assert!(!f.root.join("escaped").exists());
}
#[test]
fn natural_exit_drains_final_conpty_output_before_reporting_eof() {
    let f=Fixture::new();
    f.host.action(Action::Input { pane:f.pane.clone(),text:"[Console]::Write('X' * 131072); exit 7\r".into() }).unwrap();
    let mut ack=0; let mut output=Vec::new();
    wait(|| {
        let value=f.host.action(Action::Poll { acknowledgements:BTreeMap::from([(f.pane.clone(),ack)]) }).unwrap();
        let pane=&value["panes"][&f.pane]; ack=pane["sequence"].as_u64().unwrap();
        use base64::Engine;
        output.extend(base64::engine::general_purpose::STANDARD.decode(pane["output"].as_str().unwrap()).unwrap());
        pane["exited"] == true && pane["output"] == ""
    });
    assert!(output.iter().filter(|b| **b == b'X').count() >= 131072);
    assert_eq!(f.host.state.lock().unwrap().panes.get_mut(&f.pane).unwrap().snapshot(ack).unwrap()["exit_code"], 7);
}
#[test]
fn program_reports_never_grant_control_and_output_replays_until_acknowledged() {
    let f=Fixture::new();
    f.host.action(Action::Input { pane:f.pane.clone(),text:"[Console]::Write([char]27 + ']7501;state=done:app=test' + [char]7 + 'VISIBLE')\r".into() }).unwrap();
    wait(|| f.host.state.lock().unwrap().panes[&f.pane].counts()["done"] == 1);
    let first=f.host.action(Action::Poll { acknowledgements:BTreeMap::new() }).unwrap();
    let second=f.host.action(Action::Poll { acknowledgements:BTreeMap::new() }).unwrap();
    assert_eq!(first["panes"][&f.pane]["output"],second["panes"][&f.pane]["output"]);
    assert_eq!(second["panes"][&f.pane]["control"]["owner"],"human");
}
