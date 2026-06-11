//! AVR-safe core for the homelab framework.
//!
//! Anything in this crate must:
//!   * be `no_std`
//!   * not depend on a heap allocator
//!   * not pull in embassy or any async runtime
//!   * stay within `embedded-hal` / `embedded-hal-async` trait abstractions
//!
//! Specifically, this crate compiles on AVR (ATmega328P, 2 KB SRAM), which
//! is the most constrained target in the workspace. If you add a dependency
//! that breaks the AVR build, the dependency belongs in a separate sibling
//! crate (e.g. `shared/embassy/` if it needs async; create that crate when
//! there's real code to put in it).

#![no_std]

pub mod board;

// Re-export the traits applications commonly use.
pub use embedded_hal as hal;
pub use embedded_hal_async as hal_async;
