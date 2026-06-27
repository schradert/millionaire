# Embedded — multi-platform Rust firmware

A Cargo workspace for firmware across several MCU families, sharing as much
code as the hardware permits. One source tree builds for ESP32-S3 (Xtensa),
ESP32-C3 (RISC-V), STM32 Nucleo + Teensy 4.1 (Cortex-M), and Arduino Uno R3
(AVR).

* **Why the targets differ, and the two toolchains** → [`TARGETS.md`](TARGETS.md)
* **Exact build / flash / monitor commands** → [`QUICKSTART.md`](QUICKSTART.md)
* **This file** — the layer model, layout, scaffolding, deploy, and dev setup.

## Layers

```
┌──────────────────────────────────────────────────────────────────────┐
│ Deploy — canivete + deploy-rs (NOT in this dir)                        │
│   static/falcon.nix (repo root) → one profile per physical board.      │
│   `deploy '.#falcon'` flashes all reachable; cred-bearing boards use   │
│   `deploy-s3-wifi`. (Pulumi is gone.)                                  │
└───────────────────────────┬────────────────────────────────────────────┘
                            │ builds + flashes
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│ boards/ — per-PLATFORM binary crates                                   │
│   esp32-c3, esp32-s3, stm32-nucleo, teensy-4.1, arduino-uno-r3         │
│   wire a chip's HAL + peripherals to one or more apps.                 │
└───────────────────────────┬────────────────────────────────────────────┘
                            │ pick app(s); depend only as high as the chip allows
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│ apps/ — purposes, chip-agnostic                                        │
│   hello-world (tick loop), web-request (HTTP GET over embassy-net)     │
└───────────────────────────┬────────────────────────────────────────────┘
                            │ built on capability tiers
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│ shared/ tiers                                                          │
│   shared/wifi — ESP WiFi STA + embassy-net stack (ESP-only)            │
│   (add more tiers as needed: shared/ble, shared/storage, …)            │
└───────────────────────────┬────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│ shared/base (crate: homelab-shared) — AVR-safe core                    │
│   the `Board` trait + capability-trait extension points. MUST compile  │
│   on AVR, so it stays minimal. See TARGETS.md for the tier rationale.  │
└──────────────────────────────────────────────────────────────────────┘
```

The AVR floor is a forcing function: anything that won't build on the
ATmega328P (heap, async, wide atomics, networking) lives in a higher tier that
AVR boards don't depend on — never in `shared/base`. See
[`TARGETS.md`](TARGETS.md).

### Capability traits enforce fit at compile time

`shared/base/src/board.rs` defines `Board` (today just `NAME`) and is the home
for capability traits (`HasWifi`, `HasAdc`, …). An app requires what it needs
via bounds, so the compiler refuses to build, say, a WiFi app on the Arduino.

## Layout

```
embedded/
├── Cargo.toml          # workspace: boards are members; libs are `exclude`d (see below)
├── rustfmt.toml        # edition for per-file rustfmt (treefmt / `fmt`)
├── devenv.nix          # toolchains + tools + scaffolding/deploy/check scripts
├── .helix/ .zed/       # rust-analyzer config for this workspace
├── README.md  QUICKSTART.md  TARGETS.md
│
├── shared/
│   ├── base/           # homelab-shared — AVR-safe core
│   └── wifi/           # homelab-shared-wifi — ESP WiFi + embassy-net stack
├── apps/
│   ├── hello-world/    # homelab-hello-world
│   └── web-request/    # homelab-web-request — HTTP GET via reqwless
├── boards/
│   ├── esp32-c3/       # homelab-esp32-c3       (member)
│   ├── esp32-s3/       # homelab-esp32-s3       (member) — runs web-request over WiFi
│   ├── stm32-nucleo/   # homelab-stm32-nucleo   (member)
│   ├── teensy-4.1/     # homelab-teensy-4-1     (member)
│   └── arduino-uno-r3/ # homelab-arduino-uno-r3 (EXCLUDED — AVR toolchain)
├── templates/          # cargo-generate templates (new-app/new-shared/new-board)
└── bin/                # deploy-s3-wifi.sh, check.sh
```

**Workspace membership:** only board (binary) crates that use the default
esp-rs toolchain are `members`. Libraries (`shared/*`, `apps/*`) and the AVR
board are in `exclude` — they're consumed via path deps, but excluding them
keeps cargo from feature-unifying a chip-agnostic lib across boards that target
different chips (and keeps the AVR board, which needs a different toolchain, out
of `cargo build --workspace`). Excluded crates therefore pin their own dep
versions (they can't inherit `{ workspace = true }`).

## Scaffolding (cargo-generate)

Three devenv commands generate new crates from `templates/` and wire them into
the workspace (membership / `exclude` bookkeeping is automatic):

```bash
new-app        # apps/<name>        — a new purpose (embassy/blocking/both)
new-shared     # shared/<name>      — a new capability tier (homelab-shared-<name>)
new-board      # boards/<name>      — a new board (esp32 / cortex-m / avr kind)
```

Each prompts interactively (or pass `-d key=value --silent` to script it). After
`new-board`, register the physical unit in `static/falcon.nix` to flash it.

## Building & flashing

Two paths, depending on whether you're deploying or iterating:

**Deploy (flash physical boards)** — from the **repo root** (deploy-rs lives in
the root dev shell):

```bash
deploy '.#falcon'                    # flash every reachable board; skips disconnected
deploy '.#falcon.esp32-c3-e178'      # flash one
deploy-s3-wifi                       # flash the WiFi S3 with creds (see Secrets)
```

**Iterate (compile-check one board)** — from **`embedded/`**, in the board's dir
so its `.cargo/config.toml` (target) applies. Use **`xcargo`** (upstream nightly)
to cross-build the non-Xtensa boards locally, including on macOS:

```bash
cd boards/esp32-c3 && xcargo build --release   # C3 / STM32 / Teensy: builds anywhere
```

> Two toolchains: plain **`cargo`** = esp-rs (the default; what falcon/`deploy`
> use), **`xcargo`** = upstream nightly for local cross-builds of the C3 (RISC-V)
> and STM32/Teensy (Cortex-M). The **ESP32-S3 (Xtensa)** can't use upstream, so it
> builds on **falcon** (`deploy`/`deploy-s3-wifi`/`check` do that for you). The
> physical boards are on falcon, so *flashing* always goes through `deploy`. Full
> story + the macOS reason in [`TARGETS.md`](TARGETS.md).

## Secrets (WiFi credentials)

WiFi creds are **not** in git. They live in **Bitwarden Secrets Manager** (keys
`wifi/ssid`, `wifi/password`), and `deploy-s3-wifi` fetches them via the
locally-authenticated `bws` CLI at deploy time, injecting them into falcon's
build over SSH (transient — never on falcon's disk, never committed). The
firmware reads them via `option_env!`, so the plain `deploy` path still builds
(the board just idles without creds). See `bin/deploy-s3-wifi.sh`.

## Development

* **Editor / LSP** — open **`embedded/`** as your project (so its devenv +
  esp-rs toolchain are active). `.helix/languages.toml` and `.zed/settings.json`
  configure rust-analyzer with one `linkedProject` per esp-rs board (RA uses one
  target per project). The AVR board is opened separately (different toolchain).
* **Build locally** — `xcargo build` (upstream nightly) cross-builds the C3 /
  STM32 / Teensy on any host incl. macOS; the S3 (Xtensa) builds on falcon. Plain
  `cargo` uses esp-rs (the default). See `cargo` vs `xcargo` in `QUICKSTART.md`.
* **Format** — `fmt` (rustfmt across the workspace) or editor format-on-save.
  (Rust is deliberately *not* in the treefmt/git-hook path — devenv runs treefmt
  on every shell entry and it would choke on the Liquid templates; see devenv.nix.)
* **Lint / compile-check all boards** — `check` runs `cargo clippy` per board for
  its own target on falcon (the embedded "CI"). Exits non-zero on any failure.
* **Tests** — there's little pure logic to unit-test yet; `check` (every board
  compiles + lints for its target) is the meaningful gate. Add host `#[test]`s to
  chip-agnostic logic as it grows, and `embedded-test` (on-device via probe-rs/
  espflash) for runtime behavior when needed.

## See also

* [`QUICKSTART.md`](QUICKSTART.md) — per-board build/flash/monitor + troubleshooting.
* [`TARGETS.md`](TARGETS.md) — toolchains, what won't compile on AVR, the tiers.
* `../static/falcon.nix` — the deploy-rs node + per-board profiles.
