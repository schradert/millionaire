//! {{description}}
//!
//! This is an *app* ("purpose"): a chip-agnostic library that a board crate
//! drives. It depends only on `homelab-shared` (the AVR-safe core) and
//! `embedded-hal` traits, so it can run on any board whose capabilities it
//! requires. Add capability bounds (e.g. `B: Board + HasWifi`) to the entry
//! points as this app grows — see `shared/base/src/board.rs`.
//!
//! Two entry points, selected by Cargo features (a board picks one):
{% if runtime == "embassy" or runtime == "both" %}//!   * `embassy`  — [`run_async`]: yields to the executor between iterations.
{% endif %}{% if runtime == "blocking" or runtime == "both" %}//!   * `blocking` — [`run_blocking`]: busy-waits via an `embedded-hal` `DelayNs`.
{% endif %}
#![no_std]
{% if runtime == "embassy" or runtime == "both" %}
/// Async entry point: call `tick` once per second, forever.
///
/// TODO: replace the fixed 1 s cadence and the `tick` closure with this
/// app's real logic. Take whatever peripherals/handles you need as params.
#[cfg(feature = "embassy")]
pub async fn run_async<F: FnMut()>(mut tick: F) -> ! {
    use embassy_time::{Duration, Timer};
    loop {
        tick();
        Timer::after(Duration::from_secs(1)).await;
    }
}
{% endif %}{% if runtime == "blocking" or runtime == "both" %}
/// Blocking entry point: call `tick` once per second, forever, busy-waiting
/// via the supplied `embedded-hal` `DelayNs` between iterations.
///
/// TODO: replace the fixed 1 s cadence and the `tick` closure with this
/// app's real logic. Take whatever peripherals/handles you need as params.
#[cfg(feature = "blocking")]
pub fn run_blocking<F, D>(mut delay: D, mut tick: F) -> !
where
    F: FnMut(),
    D: embedded_hal::delay::DelayNs,
{
    loop {
        tick();
        delay.delay_ms(1000);
    }
}
{% endif %}