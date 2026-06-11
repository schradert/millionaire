#![no_std]
#![no_main]

use defmt::*;
use embassy_executor::Spawner;
use embassy_stm32::gpio::{Level, Output, Speed};
use homelab_shared::board::Board;
use {defmt_rtt as _, panic_probe as _};

struct StmNucleo;
impl Board for StmNucleo {
    // Update if you swap to a different Nucleo board.
    const NAME: &'static str = "stm32-nucleo-f446re";
}

#[embassy_executor::main]
async fn main(_spawner: Spawner) {
    let p = embassy_stm32::init(Default::default());
    info!("Embassy initialized on {}", StmNucleo::NAME);

    // Nucleo-F446RE onboard user LED is on PA5.
    let mut led = Output::new(p.PA5, Level::Low, Speed::Low);

    let mut counter: u32 = 0;
    homelab_hello_world::run_async(|| {
        counter = counter.wrapping_add(1);
        led.toggle();
        info!("Hello from {} #{}!", StmNucleo::NAME, counter);
    })
    .await;
}
