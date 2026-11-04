//! AkiTTY's portable terminal state machine. Hosts provide I/O, policy and time.
#![deny(unsafe_op_in_unsafe_fn)]

pub mod cell;
pub mod key;
pub mod parser;
pub mod screen;
pub mod terminal;
pub use terminal::{Event, Modes, Terminal};

#[cfg(target_arch = "wasm32")]
mod wasm;
