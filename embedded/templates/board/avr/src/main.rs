{%- assign app_crate = app | replace: "-", "_" -%}
#![no_std]
#![no_main]

use embedded_hal::delay::DelayNs;
use homelab_shared::board::Board;
use panic_halt as _;
use ufmt::uwriteln;

struct ThisBoard;
impl Board for ThisBoard {
    const NAME: &'static str = "{{project-name}}";
}

/// `embedded_hal::delay::DelayNs` wrapper around arduino-hal's blocking
/// delays. AVR has no embassy time backend, so we use the blocking app
/// variant and wrap arduino-hal's synchronous delays.
struct AvrDelay;
impl DelayNs for AvrDelay {
    fn delay_ns(&mut self, ns: u32) {
        // 16 MHz CPU → ~62.5 ns/cycle. Sub-µs delays aren't meaningfully
        // tunable; round up.
        arduino_hal::delay_us(ns.div_ceil(1000));
    }
    fn delay_us(&mut self, us: u32) {
        arduino_hal::delay_us(us);
    }
    fn delay_ms(&mut self, ms: u32) {
        arduino_hal::delay_ms(ms);
    }
}

#[arduino_hal::entry]
fn main() -> ! {
    let dp = arduino_hal::Peripherals::take().unwrap();
    let pins = arduino_hal::pins!(dp);
    // TODO: d13 is the Uno's onboard LED; adjust for your board.
    let mut led = pins.d13.into_output();
    // UART0 → the USB-serial chip → /dev/ttyACM* on the host.
    let mut serial = arduino_hal::default_serial!(dp, pins, 57600);

    let mut counter: u32 = 0;
    homelab_{{app_crate}}::run_blocking(AvrDelay, || {
        led.toggle();
        counter = counter.wrapping_add(1);
        let _ = uwriteln!(&mut serial, "Hello from {} #{}!", ThisBoard::NAME, counter);
    });
}
