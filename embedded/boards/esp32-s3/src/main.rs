#![no_std]
#![no_main]
#![deny(clippy::mem_forget)]

use embassy_executor::Spawner;
use embassy_time::{Duration, Timer};
use esp_backtrace as _;
use esp_hal::clock::CpuClock;
use esp_hal::interrupt::software::SoftwareInterruptControl;
use esp_hal::timer::timg::TimerGroup;
use homelab_shared::board::Board;

extern crate alloc;

struct Esp32S3;
impl Board for Esp32S3 {
    const NAME: &'static str = "esp32-s3";
}

// Required by the esp-idf bootloader.
esp_bootloader_esp_idf::esp_app_desc!();

// WiFi credentials are baked in at build time, fetched from Bitwarden Secrets
// Manager and injected over SSH by `embedded/bin/deploy-s3-wifi.sh` — they are
// never in git. `option_env!` (not `env!`) so the plain deploy-rs build path
// (`deploy '.#falcon'`), which doesn't inject creds, still compiles: without
// creds the firmware just idles instead of failing to build. Use
// `deploy-s3-wifi` to bake real creds in and enable WiFi.
const WIFI_SSID: Option<&str> = option_env!("WIFI_SSID");
const WIFI_PASSWORD: Option<&str> = option_env!("WIFI_PASSWORD");

#[esp_rtos::main]
async fn main(spawner: Spawner) -> ! {
    esp_println::logger::init_logger_from_env();

    let config = esp_hal::Config::default().with_cpu_clock(CpuClock::max());
    let peripherals = esp_hal::init(config);

    // WiFi + embassy-net need a heap. Sizes mirror the esp-hal embassy_dhcp
    // example (reclaimed region + a normal region).
    esp_alloc::heap_allocator!(#[esp_hal::ram(reclaimed)] size: 64 * 1024);
    esp_alloc::heap_allocator!(size: 32 * 1024);

    let timg0 = TimerGroup::new(peripherals.TIMG0);
    let sw_int = SoftwareInterruptControl::new(peripherals.SW_INTERRUPT);
    esp_rtos::start(timg0.timer0, sw_int.software_interrupt0);

    match (WIFI_SSID, WIFI_PASSWORD) {
        (Some(ssid), Some(password)) if !ssid.is_empty() => {
            log::info!("{}: connecting to WiFi SSID {:?}", Esp32S3::NAME, ssid);
            // Capability tier: bring up WiFi + the network stack.
            let stack =
                homelab_shared_wifi::connect(spawner, peripherals.WIFI, ssid, password).await;
            // App: do the HTTP request over that stack, forever.
            homelab_web_request::run(stack, "http://www.google.com/").await
        }
        _ => {
            log::warn!(
                "{}: no WiFi creds baked in — flash with `deploy-s3-wifi` to enable WiFi. Idling.",
                Esp32S3::NAME
            );
            loop {
                Timer::after(Duration::from_secs(60)).await;
            }
        }
    }
}
