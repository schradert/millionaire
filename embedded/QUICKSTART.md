# Quickstart — build, flash, monitor

This workspace builds separate firmwares from one source tree. Each board has a
`boards/<chip>/` crate with its own `.cargo/config.toml` (target triple + the
flash/monitor runner). See [`README.md`](README.md) for the layer model and
[`TARGETS.md`](TARGETS.md) for the toolchain story.

## Dev shell

`direnv` loads the dev shell on `cd` into `embedded/` (run `direnv allow` once,
or after a `devenv.nix`/`devenv.yaml` change). No `espup`/`rustup` — the shell
provides a single **esp-rs** Rust toolchain (Xtensa + RISC-V + Cortex-M) plus a
separate **avr-rust** nightly for the Arduino, and all the flash tools
(`espflash`, `probe-rs`, `teensy-loader-cli`, `ravedude`/`avrdude`,
`cargo-binutils`, …). See `devenv.nix`.

## Toolchains: `cargo` vs `xcargo`

Two Rust toolchains are available (plus AVR for the Arduino):

* **`cargo`** → the **esp-rs** fork (default). Required for the **ESP32-S3
  (Xtensa)**, and it's what falcon/`deploy` use. On macOS its `build-std` +
  host build-deps don't compile, so esp-rs builds happen on **falcon**.
* **`xcargo`** → an **upstream nightly**. Cross-builds the **non-Xtensa** boards
  (ESP32-C3 = RISC-V, STM32 + Teensy = Cortex-M) **locally, including on macOS**.
  The S3 can't use it (Xtensa isn't in upstream LLVM).

So, building locally: `xcargo build` for C3/STM32/Teensy on any host; the **S3
builds on falcon** (`deploy` / `deploy-s3-wifi` / `check`). The Arduino builds
locally with its own AVR toolchain. Why + the full story: [`TARGETS.md`](TARGETS.md).

## Flash physical boards (deploy-rs) — from the repo root

`deploy` lives in the **repo-root** dev shell and flashes the profiles defined
in `static/falcon.nix` (builds on falcon, skips disconnected boards):

```bash
deploy '.#falcon'                     # flash everything reachable
deploy '.#falcon.esp32-c3-e178'       # flash one board
```

Deploy profiles: `esp32-s3-lonely-binary-n16r8`, `esp32-s3-cp2102n-a`,
`esp32-s3-cp2102n-b-recovered`, `esp32-c3-e178`, `esp32-c3-fa14`,
`esp32-c3-da60`, `arduino-uno-r3`, `stm32-nucleo-f446re`, `teensy-4-1`.

### The WiFi S3 (needs credentials) — from `embedded/`

`boards/esp32-s3` runs the `web-request` app over WiFi. Creds come from
Bitwarden Secrets Manager at deploy time (never in git):

```bash
deploy-s3-wifi                        # fetch wifi/ssid+password via bws, build+flash
```

Without creds (the plain `deploy` path) the S3 builds fine and just idles. See
the Secrets section of [`README.md`](README.md).

## Iterate on one board — from `embedded/`

Run from the board's own directory so its `.cargo/config.toml` applies.

| Board | Crate | Local build | Notes |
| --- | --- | --- | --- |
| ESP32-C3 | `homelab-esp32-c3` | `xcargo` | RISC-V; `espflash` runner; USB-Serial-JTAG. |
| ESP32-S3 | `homelab-esp32-s3` | falcon only | Xtensa; `espflash` runner; runs `web-request` (see `deploy-s3-wifi`). |
| STM32 Nucleo | `homelab-stm32-nucleo` | `xcargo` | Cortex-M; `probe-rs` runner. Edit chip feature + `memory.x` + `--chip` for your variant (default F446RE). |
| Teensy 4.1 | `homelab-teensy-4-1` | `xcargo` | Cortex-M; objcopy → HEX → `teensy-loader-cli`. **Press the white button** for HalfKay. |
| Arduino Uno R3 | `homelab-arduino-uno-r3` | `cargo` (AVR) | Build from its dir — `.envrc` switches to the AVR toolchain. |

```bash
# Compile-check locally (any host, incl. macOS) with the upstream toolchain:
cd boards/esp32-c3     && xcargo build --release
cd boards/stm32-nucleo && xcargo build --release
cd boards/teensy-4.1   && xcargo build --release
cd boards/arduino-uno-r3 && cargo build --release      # AVR toolchain via .envrc

# The S3 (Xtensa) builds on falcon — flash everything via deploy (see above):
deploy '.#falcon.esp32-c3-e178'                        # build on falcon + flash
```

> The physical boards live on **falcon**, so *flashing* goes through `deploy`/
> `deploy-s3-wifi`. `xcargo`/`cargo run` locally is for fast compile-checks (and
> flashing if you have a board plugged into your own machine).

## Format, lint, check

```bash
fmt        # rustfmt every Rust file in the workspace (skips templates/)
check      # cargo clippy per board for its target, on falcon — the embedded CI
check esp32-c3 esp32-s3   # only some boards
```

Rust is also formatted on commit (treefmt). Linting/compile-checking the ESP
targets needs falcon, so it lives in `check` rather than a local git hook.

## Editor / LSP (Helix, Zed)

Open **`embedded/`** as the project so its devenv (esp-rs toolchain +
rust-analyzer) is active. `.helix/languages.toml` and `.zed/settings.json`
register each esp-rs board as a `linkedProject` (RA uses one target per
project). Open `boards/arduino-uno-r3` separately — it uses the AVR toolchain.
ESP diagnostics may be incomplete on macOS (same build-std limitation as above);
Cortex-M boards + shared libs analyze fine locally.

## Add a new app / capability / board

```bash
new-app      # apps/<name>
new-shared   # shared/<name>   (a capability tier, e.g. ble, storage)
new-board    # boards/<name>   (esp32 / cortex-m / avr)
```

These scaffold from `templates/` and update the workspace automatically. After
`new-board`, add the physical unit to `static/falcon.nix`.

## Inspecting binaries

```bash
cd boards/esp32-c3
cargo size --release        # section sizes (cargo-binutils)
cargo objdump --release -- -d --no-show-raw-insn
```

## Troubleshooting

**"Permission denied" on the serial port (Linux/falcon).** Flashing uses
`sudo`; the deploy/`deploy-s3-wifi` scripts already do `sudo -n`. For ad-hoc
runs add yourself to `dialout`.

**Board not detected.** `ls /dev/serial/by-id/` on falcon. If nothing appears
when you plug in, the cable is charge-only — use a data cable.

**ESP build fails locally with `hashbrown`/`allocator-api2` errors.** That's the
macOS esp-rs + `build-std` host-deps issue — build on falcon (`deploy`/`check`).

**Teensy: loader hangs at "Waiting for Teensy device".** Press the white button
to enter HalfKay.

**Arduino: `avrdude` sync errors / "out of sync".** Auto-reset didn't fire —
press the Uno's reset button just as flashing starts. (`deploy-rs`/the deploy
script give a timeout window and clean up a stuck `ravedude`.)

**STM32: `probe-rs` can't see the board.** Plug into the ST-Link USB; check
`probe-rs list`.

## See also

* [`README.md`](README.md) — layers, scaffolding, deploy, dev setup.
* [`TARGETS.md`](TARGETS.md) — toolchains, AVR constraints, capability tiers.
