//! A/B OTA over HTTP for ESP chips, with trial boot and rollback.
//!
//! ESP-only capability tier (esp-bootloader-esp-idf + esp-storage). [`Ota::run`]
//! needs a heap (URLs are formatted with `alloc`) and an embassy-net [`Stack`];
//! [`Ota::boot`] runs before the heap exists and must never allocate (an alloc
//! there turned the rollback target into a boot loop in testing).
//!
//! Partition layout: two OTA app slots (`ota_0`, `ota_1`) + `otadata`, no
//! factory slot. See the board's `partitions.csv` and docs/iot-ota.md.
//!
//! Server protocol (plain HTTP, LAN):
//!   GET {base}/{board}/manifest      -> "<version> <sha256-hex> <size>\n"
//!   GET {base}/{board}/<version>.bin -> app image (`espflash save-image`)
//!
//! Rollback without a rollback-enabled bootloader: espflash's stock ESP-IDF
//! bootloader is built without CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE, but it
//! still skips an otadata entry whose state is INVALID or ABORTED and falls
//! back to the other entry (the previous slot). So the app drives the state
//! machine itself:
//!
//!   NEW            first boot of a fresh image -> mark PENDING_VERIFY, trial
//!   PENDING_VERIFY previous trial never confirmed (panic/reset/hang)
//!                  -> mark ABORTED, reset -> bootloader boots the old slot
//!   trial confirm  first successful manifest fetch -> VALID
//!   trial timeout  no confirm within TRIAL_TIMEOUT -> ABORTED, reset
//!
//! A version whose otadata entry is INVALID/ABORTED is remembered (read back
//! from that slot's app descriptor) and not re-downloaded.

#![no_std]

extern crate alloc;

use alloc::format;
use alloc::string::String;
use embassy_net::Stack;
use embassy_net::dns::DnsSocket;
use embassy_net::tcp::client::{TcpClient, TcpClientState};
use embassy_time::{Duration, Instant, Timer, with_timeout};
use embedded_io_async::Read;
use embedded_storage::ReadStorage;
use embedded_storage::nor_flash::NorFlash;
use esp_bootloader_esp_idf::ota::OtaImageState;
use esp_bootloader_esp_idf::ota_updater::OtaUpdater;
use esp_bootloader_esp_idf::partitions::{
    self, AppPartitionSubType, DataPartitionSubType, PARTITION_TABLE_MAX_LEN, PartitionType,
};
use esp_hal::peripherals::FLASH;
use esp_storage::FlashStorage;
use reqwless::client::HttpClient;
use reqwless::request::{Method, RequestBuilder};
use sha2::{Digest, Sha256};

const POLL_INTERVAL: Duration = Duration::from_secs(30);
const TRIAL_TIMEOUT: Duration = Duration::from_secs(120);
const HTTP_TIMEOUT: Duration = Duration::from_secs(180);
const SECTOR: usize = FlashStorage::SECTOR_SIZE as usize;
const APP_DESC_MAGIC: u32 = 0xABCD_5432;

macro_rules! mk_static {
    ($t:ty, $val:expr) => {{
        static STATIC_CELL: static_cell::StaticCell<$t> = static_cell::StaticCell::new();
        #[deny(unused_attributes)]
        let x = STATIC_CELL.uninit().write(($val));
        x
    }};
}

pub struct Ota {
    flash: FlashStorage<'static>,
    version: &'static str,
    booted: AppPartitionSubType,
    trial: bool,
    bad_version: Option<Version>,
}

/// App-descriptor version string. Fixed-size: `Ota::boot` runs before the heap
/// exists, so nothing on the boot path may allocate.
struct Version([u8; 32], usize);

impl Version {
    fn as_str(&self) -> &str {
        core::str::from_utf8(&self.0[..self.1]).unwrap_or("")
    }
}

impl core::fmt::Debug for Version {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "{:?}", self.as_str())
    }
}

fn other(slot: AppPartitionSubType) -> AppPartitionSubType {
    if slot == AppPartitionSubType::Ota0 {
        AppPartitionSubType::Ota1
    } else {
        AppPartitionSubType::Ota0
    }
}

fn reset(why: &str) -> ! {
    log::warn!("ota: {why}; resetting");
    esp_hal::system::software_reset()
}

impl Ota {
    /// Run the boot-time state machine. Call this first thing after
    /// `esp_hal::init`, before anything that could crash. May reset the chip
    /// (to roll back an unconfirmed trial). `None` if the chip isn't running
    /// from an OTA slot (flashed without the OTA partition table).
    pub fn boot(flash: FLASH<'static>, version: &'static str) -> Option<Self> {
        let mut flash = FlashStorage::new(flash);
        let mut buf = [0u8; PARTITION_TABLE_MAX_LEN];

        let booted = {
            let pt = partitions::read_partition_table(&mut flash, &mut buf).ok()?;
            match pt
                .booted_partition()
                .ok()
                .flatten()
                .map(|p| p.partition_type())
            {
                Some(PartitionType::App(
                    s @ (AppPartitionSubType::Ota0 | AppPartitionSubType::Ota1),
                )) => s,
                other => {
                    log::warn!("ota: booted from {other:?}, not an OTA slot; OTA disabled");
                    return None;
                }
            }
        };
        let bad_version = read_bad_version(&mut flash);

        let mut ota = OtaUpdater::new(&mut flash, &mut buf).ok()?;
        let selected = ota.selected_partition().ok();
        let state = ota.current_ota_state();
        log::info!(
            "ota: version {version}, booted {booted:?}, selected {selected:?}, state {state:?}, bad {bad_version:?}"
        );

        let mut trial = false;
        match (selected, state) {
            // Blank otadata (fresh USB flash): adopt the running slot as VALID so
            // later sequence arithmetic starts from a real OTA slot.
            (Some(AppPartitionSubType::Factory), _) | (_, Err(_)) => {
                let mut data = ota.ota_data().ok()?;
                // Go via Ota0: esp-bootloader-esp-idf 0.5 computes seq 0 (invalid)
                // for Factory -> Ota1 directly.
                data.set_current_app_partition(AppPartitionSubType::Ota0)
                    .ok()?;
                data.set_current_app_partition(booted).ok()?;
                data.set_current_ota_state(OtaImageState::Valid).ok()?;
                log::info!("ota: adopted {booted:?} as VALID");
            }
            // Bootloader fell back (selected image failed to load).
            (Some(s), _) if s != booted => {
                log::warn!("ota: selected {s:?} did not boot; marking INVALID");
                ota.set_current_ota_state(OtaImageState::Invalid).ok();
            }
            (_, Ok(OtaImageState::New)) => {
                ota.set_current_ota_state(OtaImageState::PendingVerify)
                    .ok()?;
                log::info!("ota: trial boot of {version}");
                trial = true;
            }
            (_, Ok(OtaImageState::PendingVerify)) => {
                ota.set_current_ota_state(OtaImageState::Aborted).ok();
                reset("previous trial boot never confirmed, rolling back");
            }
            _ => {}
        }
        drop(ota);

        Some(Ota {
            flash,
            version,
            booted,
            trial,
            bad_version,
        })
    }

    pub fn is_trial(&self) -> bool {
        self.trial
    }

    fn set_state(&mut self, state: OtaImageState) {
        let mut buf = [0u8; PARTITION_TABLE_MAX_LEN];
        let mut ota = OtaUpdater::new(&mut self.flash, &mut buf).expect("ota partitions");
        ota.set_current_ota_state(state).expect("set state");
    }

    /// Mark the running trial image VALID.
    pub fn confirm(&mut self) {
        if self.trial {
            self.set_state(OtaImageState::Valid);
            self.trial = false;
            log::info!("ota: {} confirmed VALID", self.version);
        }
    }

    /// Poll `{base}/{board}/manifest` forever; install + reboot into newer
    /// images. `confirm_on_health = false` is a test knob: the trial is never
    /// confirmed, so it must roll back on timeout.
    pub async fn run(
        mut self,
        stack: Stack<'static>,
        base: &str,
        board: &str,
        confirm_on_health: bool,
    ) -> ! {
        let started = Instant::now();
        let tcp_state = mk_static!(TcpClientState<1, 4096, 4096>, TcpClientState::new());
        let tcp = TcpClient::new(stack, tcp_state);
        let dns = DnsSocket::new(stack);

        loop {
            if self.trial && started.elapsed() > TRIAL_TIMEOUT {
                self.set_state(OtaImageState::Aborted);
                reset("trial not confirmed in time, rolling back");
            }

            match with_timeout(HTTP_TIMEOUT, self.poll(stack, &tcp, &dns, base, board)).await {
                Ok(Ok(())) => {
                    if confirm_on_health {
                        self.confirm();
                    }
                }
                Ok(Err(e)) => log::warn!("ota: poll failed: {e}"),
                Err(_) => log::warn!("ota: poll timed out"),
            }
            Timer::after(POLL_INTERVAL).await;
        }
    }

    async fn poll(
        &mut self,
        stack: Stack<'static>,
        tcp: &TcpClient<'_, 1, 4096, 4096>,
        dns: &DnsSocket<'_>,
        base: &str,
        board: &str,
    ) -> Result<(), String> {
        stack.wait_config_up().await;
        let mut client = HttpClient::new(tcp, dns);
        let mut rx = [0u8; 2048];

        let (version, sha, size) = {
            let url = format!("{base}/{board}/manifest");
            let req = client
                .request(Method::GET, &url)
                .await
                .map_err(|e| format!("{e:?}"))?;
            let mut req = req.headers(&[("Connection", "close")]);
            let resp = req.send(&mut rx).await.map_err(|e| format!("{e:?}"))?;
            if !resp.status.is_successful() {
                return Err(format!("manifest HTTP {:?}", resp.status));
            }
            let body = resp
                .body()
                .read_to_end()
                .await
                .map_err(|e| format!("{e:?}"))?;
            let text = core::str::from_utf8(body).map_err(|_| String::from("manifest not utf8"))?;
            let mut it = text.split_whitespace();
            let (Some(version), Some(sha), Some(size)) = (it.next(), it.next(), it.next()) else {
                return Err(format!("bad manifest {text:?}"));
            };
            let size: usize = size.parse().map_err(|_| String::from("bad size"))?;
            (String::from(version), String::from(sha), size)
        };

        if version == self.version {
            log::info!("ota: up to date ({version})");
            return Ok(());
        }
        if self.bad_version.as_ref().map(Version::as_str) == Some(version.as_str()) {
            log::warn!("ota: {version} previously rolled back; skipping");
            return Ok(());
        }
        // Don't install while still on trial: confirm (or roll back) first.
        if self.trial {
            return Ok(());
        }

        log::info!("ota: {} -> {version} ({size} bytes)", self.version);
        let url = format!("{base}/{board}/{version}.bin");
        let req = client
            .request(Method::GET, &url)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let mut req = req.headers(&[("Connection", "close")]);
        let resp = req.send(&mut rx).await.map_err(|e| format!("{e:?}"))?;
        if !resp.status.is_successful() {
            return Err(format!("image HTTP {:?}", resp.status));
        }
        let target = other(self.booted);
        let digest = self.write_slot(target, size, resp.body().reader()).await?;
        let digest = hex(&digest);
        if !digest.eq_ignore_ascii_case(&sha) {
            return Err(format!(
                "sha256 mismatch: got {digest}, want {sha}; not activating"
            ));
        }

        let mut buf = [0u8; PARTITION_TABLE_MAX_LEN];
        let mut ota = OtaUpdater::new(&mut self.flash, &mut buf).map_err(|e| format!("{e:?}"))?;
        let mut data = ota.ota_data().map_err(|e| format!("{e:?}"))?;
        data.set_current_app_partition(target)
            .map_err(|e| format!("{e:?}"))?;
        data.set_current_ota_state(OtaImageState::New)
            .map_err(|e| format!("{e:?}"))?;
        log::info!("ota: {version} written to {target:?}, sha256 ok");
        Timer::after(Duration::from_millis(200)).await;
        reset("activating new image")
    }

    async fn write_slot<R: Read>(
        &mut self,
        target: AppPartitionSubType,
        size: usize,
        mut body: R,
    ) -> Result<[u8; 32], String> {
        let mut buf = [0u8; PARTITION_TABLE_MAX_LEN];
        let pt = partitions::read_partition_table(&mut self.flash, &mut buf)
            .map_err(|e| format!("{e:?}"))?;
        let part = pt
            .find_partition(PartitionType::App(target))
            .map_err(|e| format!("{e:?}"))?
            .ok_or_else(|| format!("no {target:?} partition"))?;
        if size > part.len() as usize {
            return Err(format!("image {size} > slot {}", part.len()));
        }
        let mut region = part.as_embedded_storage(&mut self.flash);

        let mut hasher = Sha256::new();
        let mut sector = [0xffu8; SECTOR];
        let mut fill = 0usize;
        let mut offset = 0u32;
        let mut total = 0usize;
        loop {
            let n = body
                .read(&mut sector[fill..])
                .await
                .map_err(|e| format!("{e:?}"))?;
            hasher.update(&sector[fill..fill + n]);
            fill += n;
            total += n;
            let eof = n == 0 || total >= size;
            if fill == SECTOR || (eof && fill > 0) {
                region
                    .erase(offset, offset + SECTOR as u32)
                    .map_err(|e| format!("erase: {e:?}"))?;
                let len = fill.next_multiple_of(16);
                region
                    .write(offset, &sector[..len])
                    .map_err(|e| format!("write: {e:?}"))?;
                offset += SECTOR as u32;
                sector.fill(0xff);
                fill = 0;
            }
            if eof {
                break;
            }
        }
        if total != size {
            return Err(format!("short image: {total} of {size} bytes"));
        }
        Ok(hasher.finalize().into())
    }
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// If an otadata entry is INVALID/ABORTED, return the version string from the
/// app descriptor of the slot it points at.
fn read_bad_version(flash: &mut FlashStorage<'static>) -> Option<Version> {
    let mut buf = [0u8; PARTITION_TABLE_MAX_LEN];
    let pt = partitions::read_partition_table(flash, &mut buf).ok()?;
    let otadata = pt
        .find_partition(PartitionType::Data(DataPartitionSubType::Ota))
        .ok()??;
    let mut bad_slot = None;
    for off in [0u32, 0x1000] {
        let mut e = [0u8; 32];
        flash.read(otadata.offset() + off, &mut e).ok()?;
        let seq = u32::from_le_bytes(e[0..4].try_into().ok()?);
        let state = u32::from_le_bytes(e[24..28].try_into().ok()?);
        if seq != u32::MAX && seq != 0 && (state == 3 || state == 4) {
            bad_slot = Some(if (seq - 1) % 2 == 0 {
                AppPartitionSubType::Ota0
            } else {
                AppPartitionSubType::Ota1
            });
        }
    }
    let app = pt.find_partition(PartitionType::App(bad_slot?)).ok()??;
    let mut head = [0u8; 256];
    flash.read(app.offset(), &mut head).ok()?;
    let at = (0..head.len() - 48)
        .step_by(4)
        .find(|&i| u32::from_le_bytes(head[i..i + 4].try_into().unwrap()) == APP_DESC_MAGIC)?;
    let v = &head[at + 16..at + 48];
    let end = v.iter().position(|&b| b == 0).unwrap_or(v.len());
    core::str::from_utf8(&v[..end]).ok()?;
    let mut buf = [0u8; 32];
    buf[..end].copy_from_slice(&v[..end]);
    Some(Version(buf, end))
}
