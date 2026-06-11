//! Board capability descriptor.
//!
//! Every board crate implements [`Board`] (or selects a subset of the
//! capability traits below). Apps require the capabilities they need
//! via trait bounds, so the compiler refuses to build an app on a board
//! that lacks a needed capability.
//!
//! Today this is a thin trait — extend with new capability traits as
//! apps grow. The intent:
//!
//! ```ignore
//! pub trait Board {
//!     const NAME: &'static str;
//! }
//!
//! pub trait HasWifi { /* methods for joining/leaving */ }
//! pub trait HasBle  { /* methods for advertising/connecting */ }
//! pub trait HasAdc  { /* type for ADC handle */ }
//! pub trait HasDac  { /* type for DAC handle */ }
//! pub trait HasDisplay { /* type for display target */ }
//!
//! // An app requires only what it uses:
//! fn humidity_sensor<B: Board + HasWifi + HasAdc>(board: B) { ... }
//! ```
//!
//! Then a board crate `impl Board for Esp32S3Board { const NAME = "esp32s3"; }`
//! and `impl HasWifi`, `impl HasAdc`, … as the chip supports each.
//! A board missing `HasWifi` simply can't compile the humidity-sensor app.

/// Identity of the running board.
pub trait Board {
    /// Short stable identifier — used for logs and identifying the running unit.
    /// e.g. `"esp32s3-n16r8"`, `"esp32c3-supermini"`, `"arduino-uno-r3"`.
    const NAME: &'static str;
}

// ─── Capability traits — add as apps need them ──────────────────────────
//
// Keep these LIGHT. A board declaring `HasWifi` advertises that it can
// reach `homelab-shared-esp::wifi` or equivalent; the concrete impl is
// the board crate's job.
//
// Today we only have NAME; expand here as we build out apps.
