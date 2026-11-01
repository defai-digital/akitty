#![deny(unsafe_op_in_unsafe_fn)]
#[cfg(not(target_os = "linux"))]
compile_error!("use the Windows wrapper to build Windows; this wrapper is Linux only");
mod desktop;
fn main() { desktop::run(tauri::generate_context!()); }
