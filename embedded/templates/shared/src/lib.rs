//! {{description}}
//!
//! A shared capability ("tier") library: reusable functionality that sits
//! above `homelab-shared` (the AVR-safe core) but below apps. Boards opt in
//! by depending on it; boards that can't support its dependency floor simply
//! don't. See ../../TARGETS.md for the tier model.
//!
//! Typical contents: a capability trait (e.g. `HasWifi`) and/or a concrete
//! helper a board calls during init. Add the deps this needs to Cargo.toml.

#![no_std]

// TODO: implement this capability. Example shapes:
//   * a trait that apps require via bounds (`pub trait HasWifi { ... }`), or
//   * a concrete `pub async fn connect(...) -> Something` a board calls.
