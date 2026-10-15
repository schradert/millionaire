#![no_std]
#![no_main]
#![deny(clippy::mem_forget)]

use embassy_executor::Spawner;
use esp_backtrace as _;
use esp_hal::clock::CpuClock;
use esp_hal::interrupt::software::SoftwareInterruptControl;
use esp_hal::timer::timg::TimerGroup;
use homelab_shared::board::Board;

extern crate alloc;

struct Esp32C3;
impl Board for Esp32C3 {
    const NAME: &'static str = "esp32-c3";
}

// Build-time inputs (all optional; see docs/iot-ota.md and bin/ota-poc.sh):
//   WIFI_SSID / WIFI_PASSWORD  from Bitwarden, injected at deploy time
//   OTA_URL                    base URL of the OTA server, e.g. http://host:8070
//   OTA_VERSION                version string; also the app descriptor version
//   OTA_FAULT                  test knob: "panic" | "nohealth"
const WIFI_SSID: Option<&str> = option_env!("WIFI_SSID");
const WIFI_PASSWORD: Option<&str> = option_env!("WIFI_PASSWORD");
const OTA_URL: Option<&str> = option_env!("OTA_URL");
const OTA_VERSION: &str = match option_env!("OTA_VERSION") {
    Some(v) => v,
    None => "dev",
};
const OTA_FAULT: Option<&str> = option_env!("OTA_FAULT");

esp_bootloader_esp_idf::esp_app_desc!(
    OTA_VERSION,
    env!("CARGO_PKG_NAME"),
    esp_bootloader_esp_idf::BUILD_TIME,
    esp_bootloader_esp_idf::BUILD_DATE,
    esp_bootloader_esp_idf::ESP_IDF_COMPATIBLE_VERSION,
    esp_bootloader_esp_idf::MMU_PAGE_SIZE,
    0,
    u16::MAX,
    esp_bootloader_esp_idf::SECURE_VERSION
);

// esp-backtrace `custom-halt`: reset on panic so a crashing OTA trial image
// reboots and rolls back instead of hanging.
#[unsafe(no_mangle)]
fn custom_halt() -> ! {
    esp_hal::system::software_reset()
}

#[esp_rtos::main]
async fn main(spawner: Spawner) -> ! {
    esp_println::logger::init_logger_from_env();

    let config = esp_hal::Config::default().with_cpu_clock(CpuClock::max());
    let peripherals = esp_hal::init(config);

    // Before anything that can fail: resolve the OTA trial state (may reset).
    let ota = homelab_shared_ota::Ota::boot(peripherals.FLASH, OTA_VERSION);

    if OTA_FAULT == Some("panic") && ota.as_ref().is_some_and(|o| o.is_trial()) {
        panic!("OTA_FAULT=panic");
    }

    esp_alloc::heap_allocator!(#[esp_hal::ram(reclaimed)] size: 64 * 1024);
    esp_alloc::heap_allocator!(size: 48 * 1024);

    let timg0 = TimerGroup::new(peripherals.TIMG0);
    let sw_int = SoftwareInterruptControl::new(peripherals.SW_INTERRUPT);
    esp_rtos::start(timg0.timer0, sw_int.software_interrupt0);

    log::info!("{} {} up", Esp32C3::NAME, OTA_VERSION);

    match (WIFI_SSID, WIFI_PASSWORD, OTA_URL, ota) {
        (Some(ssid), Some(password), Some(url), Some(ota)) if !ssid.is_empty() => {
            let stack =
                homelab_shared_wifi::connect(spawner, peripherals.WIFI, ssid, password).await;
            ota.run(stack, url, Esp32C3::NAME, OTA_FAULT != Some("nohealth"))
                .await
        }
        _ => {
            let mut counter: u32 = 0;
            homelab_hello_world::run_async(|| {
                counter = counter.wrapping_add(1);
                log::info!("Hello from {} #{counter}!", Esp32C3::NAME);
            })
            .await
        }
    }
}
