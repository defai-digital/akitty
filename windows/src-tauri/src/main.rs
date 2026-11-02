#![deny(unsafe_op_in_unsafe_fn)]
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
#[cfg(not(all(target_os = "windows", target_arch = "x86_64")))]
compile_error!("AkiTTY Experimental Windows currently supports amd64 only");
#[path = "../../../linux/src-tauri/src/desktop.rs"]
mod desktop;
fn main() { desktop::run(tauri::generate_context!()); }
