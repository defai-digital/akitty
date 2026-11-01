#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::Pty;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::Pty;
