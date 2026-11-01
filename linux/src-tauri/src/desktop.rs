use akitty_linux_experimental::{Action, Host, ipc};
use serde_json::Value;
use std::sync::Arc;
use tauri::{Emitter, Manager};

#[tauri::command]
async fn desktop_action(window: tauri::WebviewWindow, host: tauri::State<'_, Arc<Host>>, request: String) -> Result<Value, String> {
    if window.label() != "main" { return Err("only the trusted main window may control terminals".into()); }
    if request.len() > 1_048_576 { return Err("request exceeds 1 MiB".into()); }
    let action: Action = serde_json::from_str(&request).map_err(|e| e.to_string())?;
    let host = host.inner().clone();
    if matches!(action, Action::Quit {}) {
        tauri::async_runtime::spawn_blocking(move || host.shutdown()).await.map_err(|e| e.to_string())?;
        window.app_handle().exit(0); return Ok(serde_json::json!({}));
    }
    let result = tauri::async_runtime::spawn_blocking(move || host.action(action)).await.map_err(|e| e.to_string())??;
    if serde_json::to_vec(&result).map_err(|e| e.to_string())?.len() > 8 * 1_048_576 { return Err("response exceeds 8 MiB".into()); }
    Ok(result)
}

pub fn run(context: tauri::Context<tauri::Wry>) {
    tauri::Builder::default()
        .setup(|app| {
            let integration = app.path().resource_dir()?.join("shell-integration");
            let events = app.path().app_local_data_dir()?.join("agent-events");
            let host = Arc::new(Host::new(&events, &integration).map_err(std::io::Error::other)?);
            let server = ipc::Server::start(&host, &ipc::default_socket().map_err(std::io::Error::other)?).map_err(std::io::Error::other)?;
            app.manage(host); app.manage(std::sync::Mutex::new(server)); Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close(); let _ = window.emit("close-requested", ());
            }
        })
        .invoke_handler(tauri::generate_handler![desktop_action])
        .build(context).expect("cannot initialize AkiTTY Experimental")
        .run(|app, event| if matches!(event, tauri::RunEvent::Exit) { app.state::<Arc<Host>>().shutdown(); });
}
