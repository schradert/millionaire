#![no_std]
#![no_main]

use embedded_hal::delay::DelayNs;
use embedded_hal::digital::StatefulOutputPin;
use homelab_shared::board::Board;
use teensy4_bsp as bsp;
use teensy4_bsp::board;
use teensy4_panic as _;

struct Teensy41;
impl Board for Teensy41 {
    const NAME: &'static str = "teensy-4.1";
}

/// Cycle-counting `DelayNs`. Cortex-M7 @ 600 MHz → ~0.6 cycles/ns.
struct CycleDelay;
impl DelayNs for CycleDelay {
    fn delay_ns(&mut self, ns: u32) {
        let cycles = ns.saturating_mul(6) / 10;
        cortex_m::asm::delay(cycles.max(1));
    }
}

#[bsp::rt::entry]
fn main() -> ! {
    let board::Resources {
        mut pins,
        mut gpio2,
        ..
    } = board::t41(board::instances());
    let mut led = board::led(&mut gpio2, pins.p13);

    // Blink onboard LED once per second via the blocking hello-world.
    // For text output, layer imxrt-log + USB CDC; not in the minimum scaffold.
    let _ = Teensy41::NAME;
    homelab_hello_world::run_blocking(CycleDelay, || {
        let _ = led.toggle();
    });
}
