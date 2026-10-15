# IoT fleet: OTA, broker, device management

Decision doc for taking the `embedded/` boards from "USB-flashed from falcon"
to "provisioned once over USB, then network both ways". Versions below were
checked on 2026-10-14 (crates.io API, upstream repos, falcon's cargo registry);
anything not checked is marked *(unverified)*.

## TL;DR

- **OTA works today on every ESP32** with what is already in the workspace:
  `esp-bootloader-esp-idf` 0.5 (`ota` / `ota_updater` modules) + `esp-storage`
  0.9 + two OTA slots in the partition table. PoC on `esp32-c3-e178` passed
  good-update, panic-rollback, never-healthy-rollback, corrupt-image and
  recovery tests (see [PoC](#poc-esp32-c3-ota-over-http)).
- **Rollback needs no custom bootloader.** espflash's stock bootloader (ESP-IDF
  v5.5.1, built without `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE`) still skips
  otadata entries marked INVALID/ABORTED; the app drives NEW → PENDING_VERIFY →
  VALID/ABORTED itself (`shared/ota`).
- **STM32 Nucleo and Arduino Uno can't do OTA as-is** (no network). Keep them
  *tethered*: network OTA goes to a gateway (falcon) that flashes them over
  SWD/UART, which is what deploy-rs already does. Teensy 4.1 can with its
  Ethernet kit, but there is no Rust OTA stack for i.MX RT yet.
- **Recommended stack:** Mosquitto (already deployed) with mTLS from a
  cert-manager device CA + dynamic-security ACLs, Eclipse hawkBit for OTA
  rollouts, a small Rust `fleetd` for registry/shadows/HA-discovery/metrics,
  Harbor for signed firmware artifacts, Grafana/Mimir/Loki for observability.
  Everything Apache/EPL/MIT, no node limits, ~1.5 GiB RAM total *(estimate)*.

## 1. Per-board OTA matrix

| Board (falcon profile) | MCU / flash | Network | OTA now? | How | To make it OTA-capable |
|---|---|---|---|---|---|
| `esp32-c3-{e178,fa14,da60}` | ESP32-C3, 4 MB | Wi-Fi, BLE | **Yes (PoC verified)** | IDF 2nd-stage bootloader + `ota_0`/`ota_1` (2× 1.94 MB, image is ~0.56 MB) | — |
| `esp32-s3-cp2102n-a`, `-b-recovered` | ESP32-S3, 8 MB | Wi-Fi, BLE | Yes (same code, `esp32s3` features) | same | — (S3 #4 with locked secure boot stays excluded) |
| `esp32-s3-lonely-binary-n16r8` | ESP32-S3, 16 MB, 8 MB PSRAM | Wi-Fi, BLE | Yes | same, bigger slots | — |
| `stm32-nucleo-f446re` | STM32F446RE, 512 KB, 128 KB RAM | none | **No** | — | Add a network: W5500 SPI Ethernet (`embassy-net-wiznet` 0.3.0) or an ESP32-C3 as Wi-Fi co-processor (`embassy-net-esp-hosted` 0.3.0); bootloader `embassy-boot-stm32` 0.8.0. F4's 16/64/128 KB mixed sectors make ACTIVE/DFU sizing awkward (DFU ≥ ACTIVE + 1 erase page) *(sizing unverified)*. Pragmatic: stay tethered. |
| `arduino-uno-r3` | ATmega328P, 32 KB, 2 KB RAM | none | **No (not realistic)** | — | Only via a network-attached programmer (ESP as STK500-over-TCP bridge driving avrdude) — that is just "tethered" with extra steps. Replace with an ESP32-C3 for anything networked. |
| `teensy-4-1` | i.MX RT1062, 8 MB QSPI | Ethernet PHY on board (needs MagJack kit) | No | — | Ethernet kit + either FlasherX (C++/Arduino, copies the new image over itself — not A/B, not power-fail safe) or a Rust port: `imxrt-enet` 0.1.0 + `teensy4-bsp` 0.6.0 + `embassy-boot` core over a FlexSPI `NorFlash` impl. No upstream `embassy-boot-imxrt` exists *(port effort unverified)*. |

Notes
- ESP32 does **not** use embassy-boot: the ROM loads the ESP-IDF 2nd-stage
  bootloader, which picks the slot from `otadata`. `embassy-boot` 0.7.0
  (2026-03-20) has backends for nRF, RP2040/RP235x and STM32 only.
- Alternatives on ESP: `esp-hal-ota` 0.6.0 (2026-08-09) wraps the same otadata
  format; not needed now that `esp-bootloader-esp-idf` ships `OtaUpdater`.
- `esp-storage` 0.10.0 requires esp-hal 1.2 / Rust 1.95; stay on 0.9.0 with
  the workspace's esp-hal 1.1.1 until the workspace bumps.

## 2. One OTA contract across chips

Same app-level protocol everywhere; only the slot backend differs.

```
       ┌──────── device (embassy) ─────────┐
poll / │ check manifest → download → hash │  backend:
notify │ → write inactive slot → activate │   ESP:   esp-bootloader-esp-idf otadata
──────►│ → reset → trial → confirm/abort  │   STM32/nRF/RP: embassy-boot FirmwareUpdater
       └──────────────────────────────────┘          (mark_updated / mark_booted)
```

Device state machine (implemented in `embedded/shared/ota`):

| otadata state at boot | meaning | action |
|---|---|---|
| blank | fresh USB flash | adopt running slot, mark VALID |
| NEW | first boot after OTA | mark PENDING_VERIFY, start trial |
| PENDING_VERIFY | last trial never confirmed (panic, reset, hang→WDT) | mark ABORTED, reset → bootloader boots old slot |
| VALID | normal | — |

Trial confirm = first successful round-trip to the update server (later: MQTT
connected + app self-test). Trial timeout (120 s) → ABORTED + reset. Panics
reset the chip (`esp-backtrace` `custom-halt` → `software_reset`). A version
whose slot is ABORTED/INVALID is read back from that slot's app descriptor and
never re-downloaded. Note: if a board ever gets a rollback-enabled bootloader,
the PENDING_VERIFY rule must change (that bootloader sets it itself).

Missing from the PoC, needed before fleet use: a hardware watchdog (RWDT) so a
hung executor also rolls back, and per-device config outside the image (below).

### Build (Nix, reproducible)

- One derivation per (board, version): crane over the existing esp-rs/nightly
  toolchains from `embedded/devenv.nix` pins; output `app.elf`, `app.bin`
  (`espflash save-image`), `manifest.json` `{board, version, sha256, size,
  min_version}`. Version = git short rev (or tag); it is also written into the
  ESP app descriptor (`esp_app_desc!`), which is how rollbacks are recognised.
- Built on falcon / the x86 nodes as a flake check — never on the Mac.
- **No secrets in images.** Wi-Fi creds and device identity move to a
  per-device `identity` data partition written once at provisioning, so one
  image serves every board of a type (the PoC still bakes Wi-Fi creds in).

### Signing (optional, cheap)

Secure boot is not wanted (and one S3 is already bricked by a previous owner's
eFuses). Integrity: SHA-256 of the image in the manifest (PoC). Authenticity:
ed25519-sign the manifest; firmware embeds the public key. `embassy-boot` has
`ed25519-salty` / `ed25519-dalek` features for the STM32 path; on ESP verify in
the app. Key generated by Pulumi → Bitwarden → CI, like other secrets. Harbor
artifacts are additionally cosign-signed (the root devshell already loads a
cosign key).

### Storage and delivery

- **Source of truth: Harbor** (deployed) — `oras push
  harbor.trdos.me/firmware/<board>:<version> app.bin manifest.json`, cosign
  signed, retention policy for old versions. Ceph RGW (`CephObjectStore`
  deployed) is the alternative if hawkBit's S3 artifact storage is used.
- **Devices never talk OCI.** hawkBit (or `fleetd`) serves the blob over plain
  HTTPS with per-device auth; a sync job imports new Harbor versions into
  hawkBit software modules.
- **Notify + pull:** MQTT `fleet/<id>/ota` (retained, `{version, url}`) wakes
  the device; it pulls over HTTP(S) and reports progress. A slow HTTP poll
  (hawkBit DDI, configurable interval) is the fallback when MQTT is down.
- TLS on device: `embedded-tls` 0.19.0 (TLS 1.3, no alloc) or `mbedtls-rs-sys`
  0.3.1. LAN-only plain HTTP is acceptable once manifests are signed.

## 3. Broker and device-management platform

### Brokers

| | License (2026) | Per-device auth / ACL | Clustering in free tier | Footprint | Notes |
|---|---|---|---|---|---|
| **Mosquitto 2.x + dynamic-security** | EPL-2.0/EDL | mTLS (`require_certificate`, `use_identity_as_username`); dynsec clients/groups/roles with `%c`/`%u` ACL patterns, managed live via `$CONTROL/dynamic-security/v1` (since 2.0) | none (bridges only) | ~10–20 MB *(estimate)* | **already deployed** (`nixidy/apps/home/mosquitto.nix`, anonymous, in-cluster only), exporter + ServiceMonitor already wired |
| EMQX 5.9+ / 6.x | BSL 1.1 (since 5.9): single-node prod free; ≥2-node clusters need a commercial licence; cluster linking needs "non-community" licence | x509, HTTP/JWT/DB authn, rule engine, built-in dashboard | **no** (licensed) | ~200–500 MB *(estimate)* | most features, but HA is paid and licence can change again |
| VerneMQ | source Apache-2.0; official packages/images under EULA since 1.10 (commercial use = subscription) | plugins / webhooks | yes | Erlang, ~200 MB *(estimate)* | must self-build images; small community (Octavo Labs) |
| NanoMQ | MIT | password file / HTTP auth, ACL file | no *(unverified)* | very small | edge broker, good bridge; weaker management |
| HiveMQ CE | Apache-2.0 | only via extensions (file RBAC) | no (Enterprise) | JVM | fine broker, management is enterprise |

### Device platforms

| | License | What it gives | Cost here | Fit |
|---|---|---|---|---|
| **Eclipse hawkBit** 1.1.0 | EPL-2.0 | OTA campaign manager: software modules/distributions, **rollouts with groups + success/error thresholds + auto-pause**, DDI HTTP polling API with per-target security tokens, OAuth2/OIDC on mgmt API/UI | JVM ~0.7–1 GB + Postgres (CNPG) *(estimate)* | exactly "OTA jobs"; no telemetry/shadows |
| ThingsBoard CE 4.4 | Apache-2.0 | registry, attributes (≈shadows), rule engine, dashboards, OTA via shared attributes + chunked download, own MQTT/HTTP/CoAP/LwM2M transports, OAuth2 login | JVM ≥2 GB + Postgres; HA = microservices + Kafka *(estimate)* | all-in-one (Tristan has used it) but duplicates HA + Grafana, owns its own broker, OTA has no staged rollouts/rollback tracking per its docs |
| Eclipse Hono + Ditto | EPL-2.0 | protocol adapters + digital twins | Kafka/AMQP + MongoDB, many pods | overkill for ~10 devices |
| Mender | Apache-2.0 server (open core) | Linux OTA; MCU support only via the Zephyr-based MCU client *(unverified)* | many microservices | wrong fit (no esp-hal/embassy client) |
| Golioth, Memfault | SaaS | OTA, observability | — | not self-hostable; noted only |

### Recommendation — "AWS IoT Core from scratch"

| AWS IoT piece | Here | Why |
|---|---|---|
| Device gateway / broker | **Mosquitto** (existing release) + TLS listener on the internal gateway; anonymous listener kept cluster-internal for zigbee2mqtt/govee2mqtt | no node limits, tiny, already monitored |
| Identity / certs | **cert-manager** CA `Issuer` `iot-device-ca` (self-signed root in-cluster); per-device `Certificate` (CN = device id) | declarative, rotates broker cert automatically |
| Policies | **dynsec** roles: `device` = pub `fleet/%u/#` (except `ota`), sub `fleet/%u/cmd/#`, `fleet/%u/ota`, `fleet/%u/shadow/desired` | per-device topic isolation |
| Registry + fleet provisioning | **`fleetd` (Rust)**: devices declared in Nix (`id, board, mac, channel`); reconciles dynsec clients, cert-manager Certificates, hawkBit targets | single source of truth in git, no manual secrets |
| Shadows / twins | retained `fleet/<id>/shadow/{reported,desired}`; `fleetd` computes delta → `fleet/<id>/shadow/delta` | AWS classic-shadow semantics without a DB |
| Rules | Home Assistant automations (MQTT discovery entities) + `fleetd` → Prometheus metrics / Loki logs | reuse HA; no second rule engine |
| Jobs / OTA | **hawkBit** rollouts; HA MQTT `update` entity per device shows installed/latest and can trigger | staged rollouts + error thresholds for free |
| UI auth | Keycloak OIDC for hawkBit, Grafana, HA (devices never use Keycloak) | matches "SSO for every admin app" |
| Observability | mosquitto-exporter (exists), `fleetd` `/metrics` (last_seen, rssi, fw version, ota state per device) → Mimir; device logs over MQTT → `fleetd` → Loki | Grafana dashboards + alerts on stuck rollouts |

HA story: Mosquitto is a single replica (OSS has no clustering); persistence on
the existing PVC, devices reconnect with backoff and buffer telemetry, OTA is
pull-based so a broker outage only delays it. hawkBit is stateless over CNPG
(HA-capable). `fleetd` is stateless (state = git + retained messages).
Licensing: EPL-2.0 (Mosquitto, hawkBit), Apache-2.0 (cert-manager), own code.

Runner-up: ThingsBoard CE, if one UI for telemetry+OTA matters more than Rust,
git-declared state and staged rollouts.

## 4. Fleet provisioning

```
dev machine (repo)                       cluster                         device
──────────────────                       ───────                         ──────
1. add device to fleet devices.nix  ──►  fleetd/ArgoCD: Certificate,
                                         dynsec client, hawkBit target
                                         ESO PushSecret → Bitwarden
                                         iot/<id>/{tls.crt,tls.key,ca.crt,
                                         ota-token}
2. `iot-provision <id>` on falcon:
   bws → identity blob (wifi/*, mqtt host, cert, key, CA, ota token)
   → postcard + CRC → `identity` data partition
   espflash flash --partition-table … --target-app-partition ota_0
            --erase-parts otadata  + write-bin identity  ─────────────────►  USB, once
3.                                                                          boot: adopt slot, VALID
                                                                            mTLS MQTT connect (LWT)
                                       ◄── birth, HA discovery, shadow/reported
                                       ── shadow/desired, cmd/*, ota ──────►
                                       ◄── telemetry, logs, ota progress
                                       HTTPS pull from hawkBit ◄───────────  trial → confirm/rollback
```

- Keys never exist in git; they live in the cluster Secret and Bitwarden, and
  transit to falcon over SSH only at provisioning time (as `deploy-s3-wifi`
  does today).
- Device certs are long-lived; revocation = disable the dynsec client +
  hawkBit target. Re-provisioning (new key) is a USB operation; CA/broker
  rotation is pushed as a new CA bundle over MQTT before the switch.
- Board-agnostic: STM32/Teensy get the same identity blob once they have a
  network; tethered boards (Uno, Nucleo today) are represented by the gateway.

## 5. Test plan (falcon's boards, runnable by an agent)

`embedded/bin/ota-test.sh` (devenv: `ota-test`) drives `bin/ota-falcon.sh` on
falcon: builds images there, serves them with a throwaway HTTP server on
`192.168.50.215:8070`, USB-flashes, then reads the C3's USB-serial and asserts
on log lines. Wi-Fi creds come from Bitwarden like `deploy-s3-wifi`.

| Scenario | Steps | Pass when |
|---|---|---|
| `flash` | build v1, publish, USB-flash into ota_0 with blank otadata | `up to date (v1)` |
| `good` | publish v2 | `v1 -> v2`, `trial boot of v2`, `v2 confirmed VALID` |
| `panic` | v3 built with `OTA_FAULT=panic` (panics during trial) | panic → `never confirmed, rolling back` → boots v2 → `v3 previously rolled back` |
| `nohealth` | v4 with `OTA_FAULT=nohealth` (never confirms) | `trial not confirmed in time` → v2 → `v4 previously rolled back` |
| `corrupt` | v5 published with a wrong SHA-256 | `sha256 mismatch`, no reboot, still on v2 |
| `recover` | publish good v6 after the failures | `v6 confirmed VALID` (slot arithmetic still right after aborted entries) |

Run: `ota-test` (all) or `ota-test good panic`; `OTA_RUN_ID` keeps versions
stable across separate invocations; `OTA_REMOTE_DIR` points at another falcon
checkout. Still to add: power loss mid-download (`espflash reset` while
writing → old slot must boot, next poll retries), hang during trial (needs the
RWDT), server unreachable (no reboot, no state change), the same suite on
`esp32-s3-cp2102n-a`, and a soak loop of 50+ updates for flash-wear/leak checks.

## PoC: ESP32-C3 OTA over HTTP

Code: `embedded/shared/ota` (ESP-only tier like `shared/wifi`),
`embedded/boards/esp32-c3/{partitions.csv,src/main.rs}`, test drivers in
`embedded/bin/`. The C3 board now runs Wi-Fi + OTA when built with
`WIFI_SSID`/`WIFI_PASSWORD`/`OTA_URL`, and the old hello-world otherwise;
`static/falcon.nix` flashes it with the OTA partition table.

Result on `esp32-c3-e178` (2026-10-14, image ~563 KB, espflash 4.4.0):
all six scenarios pass. Excerpt of the rollback path:

```
ota: te-2 -> te-3 (563424 bytes)
ota: te-3 written to Ota0, sha256 ok
ota: trial boot of te-3
PANIC ... OTA_FAULT=panic                      (reset via custom-halt)
ota: version te-3, ..., state Ok(PendingVerify)
ota: previous trial boot never confirmed, rolling back; resetting
boot: Loaded app from partition at offset 0x200000
ota: version te-2, booted Ota1, ..., state Ok(Aborted), bad Some("te-3")
ota: te-3 previously rolled back; skipping
```

Findings
- The first rollback run boot-looped the *good* image: `Ota::boot` allocated
  (version string) before the heap existed, which only happens once an
  ABORTED entry exists. Fixed (boot path is allocation-free) — the
  known-good image's rollback path is the one that must never break, so this
  suite has to run on every change to `shared/ota`.
- Downloads of ~0.56 MB sometimes exceeded 60 s on the C3; the per-poll
  timeout is 180 s.
- Unrelated to OTA: both C3s intermittently loop on Wi-Fi
  `AuthenticationExpired` against the home AP (`lanyard`, ch 10, −65 dBm) for
  several minutes after rapid reconnects, then connect. Not resolved (AP-side
  or esp-radio 0.18); the test timeouts absorb it.
