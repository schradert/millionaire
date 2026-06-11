{%- if mcu == "esp32-c3" -%}{%- assign board_struct = "Esp32C3" -%}{%- else -%}{%- assign board_struct = "Esp32S3" -%}{%- endif -%}
{%- assign app_crate = app | replace: "-", "_" -%}
#![no_std]
#![no_main]
#![deny(clippy::mem_forget)]

use embassy_executor::Spawner;
use esp_backtrace as _;
use esp_hal::clock::CpuClock;
use esp_hal::interrupt::software::SoftwareInterruptControl;
use esp_hal::timer::timg::TimerGroup;
use homelab_shared::board::Board;

struct {{board_struct}};
impl Board for {{board_struct}} {
    const NAME: &'static str = "{{project-name}}";
}

// Required by the esp-idf bootloader.
esp_bootloader_esp_idf::esp_app_desc!();

#[esp_rtos::main]
async fn main(_spawner: Spawner) -> ! {
    esp_println::logger::init_logger_from_env();

    let config = esp_hal::Config::default().with_cpu_clock(CpuClock::max());
    let peripherals = esp_hal::init(config);

    let timg0 = TimerGroup::new(peripherals.TIMG0);
    let sw_int = SoftwareInterruptControl::new(peripherals.SW_INTERRUPT);
    esp_rtos::start(timg0.timer0, sw_int.software_interrupt0);

    log::info!("Embassy initialized on {}", {{board_struct}}::NAME);

    // TODO: wire up this board's peripherals and call your app. The default
    // runs homelab-{{app}}'s async loop with a logging tick.
    let mut counter: u32 = 0;
    homelab_{{app_crate}}::run_async(|| {
        counter = counter.wrapping_add(1);
        log::info!("Hello from {} #{counter}!", {{board_struct}}::NAME);
    })
    .await
}
