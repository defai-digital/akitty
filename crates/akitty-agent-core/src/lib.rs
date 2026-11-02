//! Shared agent protocol and authority primitives. No UI, PTY, or terminal grid.
#![deny(unsafe_op_in_unsafe_fn)]

pub mod chrome;
pub mod control;
pub mod program_status;
pub mod shell;

#[cfg(unix)]
pub mod child;
