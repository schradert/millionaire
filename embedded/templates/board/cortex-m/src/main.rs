{%- assign app_crate = app | replace: "-", "_" -%}
#![no_std]
#![no_main]

use defmt::*;
use embassy_executor::Spawner;
use embassy_stm32::gpio::{Level, Output, Speed};
use homelab_shared::board::Board;
use {defmt_rtt as _, panic_probe as _};

struct ThisBoard;
impl Board for ThisBoard {
    const NAME: &'static str = "{{project-name}}";
}

#[embassy_executor::main]
async fn main(_spawner: Spawner) {
    let p = embassy_stm32::init(Default::default());
    info!("Embassy initialized on {}", ThisBoard::NAME);

    // TODO: set the correct user-LED pin for your board ({{led_pin}} is the
    // Nucleo-F446RE default) and wire up the rest of your peripherals.
    let mut led = Output::new(p.{{led_pin}}, Level::Low, Speed::Low);

    let mut counter: u32 = 0;
    homelab_{{app_crate}}::run_async(|| {
        counter = counter.wrapping_add(1);
        led.toggle();
        info!("Hello from {} #{}!", ThisBoard::NAME, counter);
    })
    .await;
}
