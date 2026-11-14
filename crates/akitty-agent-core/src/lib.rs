//! Shared agent protocols, authority primitives, and Unix child cleanup.
//! No UI or terminal grid; hosts own PTY creation and I/O.
#![deny(unsafe_op_in_unsafe_fn)]

pub mod chrome;
pub mod control;
pub mod program_status;
pub mod shell;

#[cfg(unix)]
pub mod child;
