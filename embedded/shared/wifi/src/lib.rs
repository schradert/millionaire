//! ESP WiFi STA + embassy-net stack helper.
//!
//! ESP-only capability tier (depends on esp-radio), so it sits above
//! `homelab-shared` but is NOT AVR-safe — only ESP boards depend on it.
//! See ../../TARGETS.md for the tier model.
//!
//! [`connect`] brings up a WiFi station and an embassy-net DHCP stack,
//! spawning the connection-management and net-runner tasks, and returns the
//! [`Stack`] for apps to use. Adapted from the esp-hal `embassy_dhcp`
//! example (esp-radio v0.18).
//!
//! Requirements (the board must do these before calling `connect`):
//!   * initialise a heap (`esp_alloc::heap_allocator!`)
//!   * start the esp-rtos scheduler (`esp_rtos::start`)

#![no_std]

use embassy_executor::Spawner;
use embassy_net::{Runner, Stack, StackResources};
use embassy_time::{Duration, Timer};
use esp_hal::peripherals::WIFI;
use esp_hal::rng::Rng;
use esp_radio::wifi::{Config, ControllerConfig, Interface, WifiController, sta::StationConfig};

// Allocate a `'static` from a `StaticCell` (the no-nightly-needed pattern from
// the esp-hal examples).
macro_rules! mk_static {
    ($t:ty, $val:expr) => {{
        static STATIC_CELL: static_cell::StaticCell<$t> = static_cell::StaticCell::new();
        #[deny(unused_attributes)]
        let x = STATIC_CELL.uninit().write(($val));
        x
    }};
}

/// Connect to a WiFi network (STA) and bring up an embassy-net stack with DHCP.
///
/// Spawns the connection-management task (auto-reconnect) and the net-runner
/// task, then returns the [`Stack`]. The link won't have an IP yet — call
/// `stack.wait_config_up().await` (apps typically do this) before using it.
pub async fn connect(
    spawner: Spawner,
    wifi: WIFI<'static>,
    ssid: &str,
    password: &str,
) -> Stack<'static> {
    let station_config = Config::Station(
        StationConfig::default()
            .with_ssid(ssid)
            .with_password(password.into()),
    );

    let (controller, interfaces) = esp_radio::wifi::new(
        wifi,
        ControllerConfig::default().with_initial_config(station_config),
    )
    .expect("failed to initialise Wi-Fi controller");

    let wifi_interface = interfaces.station;

    let net_config = embassy_net::Config::dhcpv4(Default::default());
    let rng = Rng::new();
    let seed = ((rng.random() as u64) << 32) | rng.random() as u64;

    let (stack, runner) = embassy_net::new(
        wifi_interface,
        net_config,
        mk_static!(StackResources<3>, StackResources::<3>::new()),
        seed,
    );

    spawner.spawn(connection(controller).unwrap());
    spawner.spawn(net_task(runner).unwrap());

    stack
}

/// Keeps the station associated: connect, wait for disconnect, retry.
#[embassy_executor::task]
async fn connection(mut controller: WifiController<'static>) {
    loop {
        match controller.connect_async().await {
            Ok(info) => {
                log::info!("wifi: connected ({info:?})");
                let _ = controller.wait_for_disconnect_async().await;
                log::warn!("wifi: disconnected, reconnecting");
            }
            Err(e) => {
                log::warn!("wifi: connect failed ({e:?}), retrying in 5s");
                Timer::after(Duration::from_millis(5000)).await;
            }
        }
    }
}

/// Drives the embassy-net stack (smoltcp poll loop).
#[embassy_executor::task]
async fn net_task(mut runner: Runner<'static, Interface<'static>>) {
    runner.run().await
}
