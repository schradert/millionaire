//! Hello-world purpose.
//!
//! Calls a user-supplied `tick` closure once per second. The closure does
//! whatever the board can — toggle an LED, print to USB-Serial-JTAG, write
//! to UART, send a defmt log frame, anything.
//!
//! Two flavors, selected by Cargo features:
//!
//! * `embassy` (default): `run_async(tick).await` — pauses the executor
//!   between ticks (other tasks run, CPU sleeps).
//! * `blocking`: `run_blocking(delay, tick)` — busy-waits using an
//!   `embedded_hal::delay::DelayNs` impl. Used by boards without an
//!   embassy executor (AVR, currently also Teensy).

#![no_std]

#[cfg(feature = "embassy")]
pub use embassy_impl::run_async;

#[cfg(feature = "embassy")]
mod embassy_impl {
    use embassy_time::{Duration, Timer};

    /// Async hello-world: call `tick` once per second forever.
    pub async fn run_async<F: FnMut()>(mut tick: F) -> ! {
        loop {
            tick();
            Timer::after(Duration::from_secs(1)).await;
        }
    }
}

/// Blocking hello-world: call `tick` once per second forever, busy-waiting
/// via the supplied `DelayNs` implementor between calls.
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
