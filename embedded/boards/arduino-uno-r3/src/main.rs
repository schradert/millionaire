#![no_std]
#![no_main]

use embedded_hal::delay::DelayNs;
use homelab_shared::board::Board;
use panic_halt as _;
use ufmt::uwriteln;

struct ArduinoUno;
impl Board for ArduinoUno {
    const NAME: &'static str = "arduino-uno-r3";
}

/// `embedded_hal::delay::DelayNs` wrapper around `arduino_hal::delay_*`.
/// The Uno has no embassy time backend, so we use the blocking
/// `homelab_hello_world` variant and wrap arduino-hal's sync delays.
struct AvrDelay;
impl DelayNs for AvrDelay {
    fn delay_ns(&mut self, ns: u32) {
        // 16 MHz CPU → ~62.5 ns per cycle. Sub-µs delays aren't meaningfully
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
    let mut led = pins.d13.into_output();
    // UART0 goes through the ATmega16U2 USB chip → /dev/ttyACM0 on the host.
    let mut serial = arduino_hal::default_serial!(dp, pins, 57600);

    let mut counter: u32 = 0;
    homelab_hello_world::run_blocking(AvrDelay, || {
        led.toggle();
        counter = counter.wrapping_add(1);
        let _ = uwriteln!(&mut serial, "Hello from {} #{}!", ArduinoUno::NAME, counter);
    });
}
