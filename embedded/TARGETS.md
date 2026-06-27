# Targets, toolchains, and the AVR problem

This workspace builds firmware for five chip families that are *wildly*
different in capability — from a 600 MHz Cortex-M7 with a megabyte of RAM
down to an 8-bit AVR with **2 KB** of SRAM. This document explains:

1. why there are **two Rust toolchains** in play and why they can't be merged,
2. **what won't compile** on the weakest target (AVR),
3. the **capability-tier design** that keeps shared code portable, and
4. what the lowly Arduino is actually *good* for.

If you only remember one thing: **`shared/base` must compile on AVR**, and
AVR is brutal. Anything fancier than `embedded-hal` traits belongs in a
higher tier that AVR boards don't depend on.

---

## 1. Toolchains, and why

| Board family         | Target triple                 | Default toolchain | Local cross-build |
| -------------------- | ----------------------------- | ----------------- | ----------------- |
| ESP32-S3             | `xtensa-esp32s3-none-elf`     | **esp-rs**        | — (Xtensa → falcon) |
| ESP32-C3             | `riscv32imc-unknown-none-elf` | **esp-rs**        | `xcargo` (upstream) |
| STM32 Nucleo         | `thumbv7em-none-eabihf`       | **esp-rs**        | `xcargo` (upstream) |
| Teensy 4.1           | `thumbv7em-none-eabihf`       | **esp-rs**        | `xcargo` (upstream) |
| Arduino Uno R3 (AVR) | `avr-none`                    | **avr-rust**      | `cargo` (avr-rust) |

The **default** is esp-rs (what falcon/`deploy` use); **avr-rust** handles the
Arduino. A third **upstream nightly** (`xcargo`) cross-builds the non-Xtensa
boards locally — see "Cross-building locally" below. The core reason there's
more than one toolchain: no single Rust build can target everything
we need:

### esp-rs — covers four of the five families

`esp-rs` is **Espressif's fork of nightly Rust** (provisioned via the
`esp-rs-nix` flake, see `devenv.nix`). It exists because the **Xtensa**
architecture used by the ESP32-S3 **is not in upstream LLVM** — Espressif
maintains an out-of-tree LLVM backend for it, and bundles a matching Rust
toolchain. Because that toolchain is nightly-based and ships `build-std`,
it *also* happily targets:

* RISC-V (`riscv32imc-…`) — the ESP32-C3, and
* ARM Cortex-M (`thumbv7em-…`) — STM32 and Teensy.

So one toolchain handles every board *except* the Arduino. That's the
default toolchain configured in `devenv.nix` under `languages.rust`.

### avr-rust — exists solely for the Arduino

AVR's LLVM backend *is* upstream — but it is a **Tier 3** Rust target with
two inconvenient properties:

1. It needs `-Z build-std` (nightly only) because no prebuilt `core` ships
   for AVR.
2. The AVR codegen backend **regresses frequently** across nightlies, so
   `avr-hal` (the community HAL) pins to specific known-good nightly dates.

We pin to **`nightly-2025-04-27`** (the date `avr-hal`'s template used at
the time), provisioned via `rust-overlay`. See `avr-rust` in `devenv.nix`.

### Why they can't be one toolchain

* `esp-rs` is the *Espressif fork*; it does **not** carry the AVR backend
  in a working state, and it isn't pinned to an `avr-hal`-blessed nightly.
* Upstream nightly carries AVR but **not** the Xtensa backend (that only
  lives in Espressif's LLVM fork).

So they're mutually exclusive: one has Xtensa-but-no-usable-AVR, the other
has AVR-but-no-Xtensa. We need both, so we ship both.

### How the switch happens (it's just `PATH`)

The esp-rs toolchain is the default for the whole `embedded/` dev shell.
The Arduino crate flips to `avr-rust` purely via `PATH`, scoped to its own
directory:

* `devenv.nix` exports the avr-rust store path as `env.AVR_RUST` but does
  **not** put it on `PATH` (that would shadow esp-rs everywhere).
* `boards/arduino-uno-r3/.envrc` does `source_up` (inherit the parent
  shell: ravedude, avr-gcc, avrdude, …) then `PATH_add "$AVR_RUST/bin"`.

The upshot: `cargo` resolves to esp-rs everywhere **except** when your
shell's CWD is inside `boards/arduino-uno-r3/`, where it resolves to
avr-rust. This is also why the Arduino crate is in the workspace's
`exclude` list — `cargo build --workspace` from the root would try to
build it with the *wrong* toolchain. (See `WORKSPACE_LAYOUT` notes in the
root `Cargo.toml`.)

### Cross-building locally, and the macOS limitation (`xcargo`)

The esp-rs toolchain builds everything **on falcon** (Linux). On **macOS** it
can't: with `build-std` set, cargo also build-std's the *host* build-dependencies
of `esp-hal` (`esp-config` → `hashbrown`/`allocator-api2`), and on Darwin the
rebuilt host `core` conflicts with the prebuilt host std — `hashbrown` fails to
compile with hundreds of "cannot find `Some`" errors. (esp-rs ships a complete
`aarch64-apple-darwin` host std; this is a `build-std`-vs-host interaction
specific to the fork's Darwin packaging, not a missing-std problem. The official
`espup` toolchain doesn't hit it.)

The fix for everything **except the S3**: those targets are *upstream* Rust
targets. The C3 is RISC-V (`riscv32imc-unknown-none-elf`) and STM32/Teensy are
Cortex-M (`thumbv7em-none-eabihf`) — a plain **upstream nightly** with `rust-src`
build-std's `core`/`alloc` for them from source on any host, including macOS,
with no host-build-dep breakage. So we ship a third toolchain (`upstream-rust`
in `devenv.nix`) and a wrapper:

* **`cargo`** → esp-rs (default). What falcon/`deploy` use; required for the S3.
* **`xcargo`** → upstream nightly. `cd boards/esp32-c3 && xcargo build --release`
  cross-builds the C3 / STM32 / Teensy locally. Backwards compatible — plain
  `cargo`, the falcon flow, and the S3 are untouched.

The **ESP32-S3 (Xtensa) is the one holdout**: upstream LLVM has no Xtensa backend
(`xcargo` errors with *"'esp32s3' is not a recognized processor"*), so the S3
must use esp-rs and therefore builds on **falcon**. Closing that gap means either
switching the Darwin esp toolchain to `espup`'s (known to work) or fixing
`esp-rs-nix`'s `build-std`/host behaviour — tracked, not yet done.

Verified locally on macOS via `xcargo`: ✅ esp32-c3, ✅ stm32-nucleo,
✅ teensy-4.1, ✅ arduino-uno-r3 (its own avr-rust); ❌ esp32-s3 (Xtensa → falcon).

**Does the cross-built firmware actually run?** Yes — the upstream-built C3 was
flashed to real hardware and boots + prints over USB-serial (`Hello from
esp32-c3 #1!…`), same as the esp-rs build. That's the meaningful proof: codegen
for `riscv32imc`/`thumbv7em` comes from *upstream LLVM*, which esp-rs uses too —
esp-rs only *adds* Xtensa. So an upstream build of a RISC-V/Cortex-M board is the
same machine code path as esp-rs, just produced by a toolchain whose host side
isn't broken on macOS. (STM32/Teensy build + flash cleanly; the Arduino runs as
verified earlier.)

### Host support matrix

✅ works · ⚠️ caveat · ❌ exception. "Others" (any Linux x86_64/aarch64 host)
behave like falcon; other macOS hosts behave like millionaire.

| Capability                                   | falcon (x86_64-linux) | millionaire (aarch64-darwin) |
| -------------------------------------------- | --------------------- | ---------------------------- |
| Build C3 / STM32 / Teensy (`xcargo`)         | ✅                    | ✅                           |
| Build Arduino (`cargo`, avr-rust)            | ✅                    | ✅                           |
| Build **ESP32-S3** (Xtensa, esp-rs)          | ✅                    | ❌ build on falcon (see below) |
| Build *any* board with `cargo` (esp-rs)      | ✅                    | ❌ use `xcargo` for non-Xtensa |
| `deploy` / `deploy-s3-wifi` / `check`        | ✅                    | ✅ (drive falcon over SSH)   |
| Flash a board                                | ✅ (boards attached)  | ⚠️ only if attached locally; else `deploy` |
| rust-analyzer                                | ✅ all boards         | ⚠️ esp diagnostics limited¹  |

The **only hard exception on any host is building the ESP32-S3 (Xtensa) off
Linux** — everything else works everywhere. ¹RA uses the default esp-rs
toolchain, which doesn't analyze esp crates on macOS; Cortex-M boards + the
shared libs analyze fine. Pointing RA at the upstream toolchain for the
non-Xtensa boards would close that gap (a follow-up).

---

## 2. What won't compile on AVR

The ATmega328P on the Uno is the floor: 8-bit, 16 MHz, no FPU, no hardware
divide, no atomic compare-and-swap, 32 KB flash, **2 KB SRAM**. In practice
that rules out a lot of "but it's `no_std`!" crates:

| Thing                                   | Why it breaks on AVR                                                                                                                                              |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`alloc` / any heap-using crate**      | No default allocator, and 2 KB SRAM means most heap users blow the data segment on the first allocation anyway.                                                  |
| **Atomics wider than 1 byte**           | AVR has no compare-and-swap. `AtomicU32`, `AtomicUsize`, `AtomicPtr`, … simply do not exist on the target.                                                       |
| **`portable-atomic` + `unsafe-assume-single-core`** | The usual workaround for the above — but that feature is **rejected on `riscv32imc`** (our ESP32-C3). A dep that enables it by default builds on AVR yet breaks the C3. *(This is exactly why `heapless` was removed from `shared/base`.)* |
| **Embassy and most async**              | Embassy's executor uses 32-bit atomics for its run-queue and wakers. Not portable to AVR. (Hence the `blocking` variant of `hello-world`.)                       |
| **`usize` math that assumes ≥32 bits**  | On AVR `usize` is **16 bits**. Crates that implicitly assume 32-bit indices/IDs fail to compile; 64-bit and float math compiles but pulls in software-emulation routines that bloat the 32 KB flash fast. |

**The rule baked into `shared/base/src/lib.rs`:** if a dependency isn't
`no_std` + no-heap + no-async + `embedded-hal`-only, it does **not** go in
`shared/base`. It goes in a higher-tier crate that AVR boards don't pull.

---

## 3. The capability-tier design

Your intuition is right: the library shared across *all* targets has to be
minimal, and the chips with real resources deserve a richer base of their
own. The design expresses that as **tiers of crates**, where each board
depends only as high as its hardware allows:

```
        ┌─────────────────────────────────────────────────────────┐
  Tier  │  apps/*          purposes — chip-agnostic where possible  │
   ↑    └─────────────────────────────────────────────────────────┘
   │     depend only as high as the board's hardware permits
   │    ┌─────────────────────────────────────────────────────────┐
   │    │  (future) shared/esp      WiFi / BLE / ESP-NOW — ESP only │
   │    │  (future) shared/async    embassy helpers — every non-AVR │
   │    └─────────────────────────────────────────────────────────┘
   │    ┌─────────────────────────────────────────────────────────┐
  base  │  shared/base   AVR-safe core: embedded-hal traits, the    │
        │                `Board` trait + capability descriptors.    │
        │                MUST compile on AVR. Every board depends    │
        │                on this and nothing weaker exists.          │
        └─────────────────────────────────────────────────────────┘
```

Two mechanisms keep this honest:

### a) The AVR floor stops `shared/base` from bloating

`shared/base` is the only crate *every* board depends on, and it has to
build for the Arduino. The 2 KB ceiling is an architectural forcing
function: you physically cannot smuggle async, networking, or a heap into
the shared core, because the AVR build would break immediately. When you
want richer shared functionality, you create a **sibling tier crate** (e.g.
`shared/async` for embassy helpers, `shared/esp` for WiFi/BLE) and only the
boards that can run it depend on it. AVR never sees it.

> The earlier `shared/embassy` and `shared/esp` crates were removed once
> they had no real code in them — recreate them (as separate crates, not by
> growing `shared/base`) when there's actual functionality to host.

### b) Capability traits make the *compiler* enforce fit

`shared/base/src/board.rs` defines a `Board` trait (just `NAME` today) and
is the home for **capability traits** — `HasWifi`, `HasAdc`, `HasDisplay`,
… An app declares what it needs as trait bounds:

```rust
// An app that needs WiFi + an ADC won't even compile on a board lacking them.
fn humidity_sensor<B: Board + HasWifi + HasAdc>(board: B) { /* … */ }
```

A board `impl`s only the capabilities its chip actually has. Try to build
a WiFi app on the Arduino and you get a *compile error*, not a runtime
surprise. The traits live in the AVR-safe base (they're just trait
definitions — no implementation, so they cost nothing), while the concrete
`impl`s live in each board crate.

---

## 4. So what is the Arduino even *for*?

If AVR can't do async, networking, or a heap, why keep it around? Because
"underpowered" and "useless" aren't the same thing. The ATmega328P is a
fantastic fit for a specific class of job:

* **One dead-simple, deterministic job.** Read a sensor, debounce a button,
  drive a relay, step a motor. 2 KB is plenty when the program *is* a loop.
  No RTOS scheduling jitter, no cache, no speculative anything — cycle
  counts are exact and reproducible, which matters for bit-banged protocols
  and precise timing.
* **5 V tolerance and electrical robustness.** Unlike the 3.3 V ESP/STM
  parts, the Uno's I/O is 5 V and notoriously hard to kill. Great for
  breadboards, classrooms, and noisy real-world wiring.
* **The shield + library ecosystem.** Two decades of hardware shields and
  reference designs assume an Uno footprint and 5 V logic.
* **A bulletproof bootloader.** Flash over plain USB-serial with no probe,
  no special hardware — `ravedude` → `avrdude` → optiboot. (When the
  auto-reset is flaky you press the button; see `static/falcon.nix`.)
* **It's cheap and replaceable.** Brick one, grab another. Contrast the
  ESP32-S3 we permanently lost to a locked flash-encryption eFuse.

What it is emphatically **not** for: anything touching the network, async
concurrency, crypto, large buffers, or rich data structures. Reach for an
ESP32-C3/S3 (WiFi/BLE, RISC-V/Xtensa, hundreds of KB of RAM) or an STM32 /
Teensy (fast Cortex-M, lots of peripherals) for those. The Arduino earns
its slot in the workspace precisely because it keeps the shared core
honest — and because sometimes the right tool genuinely is a 16 MHz 8-bit
loop that never crashes.

---

## See also

* `README.md` — what the layers mean and how they fit together.
* `QUICKSTART.md` — build / flash commands per board.
* `devenv.nix` — where both toolchains are provisioned.
* `static/falcon.nix` (repo root) — how each board is flashed via deploy-rs.
* `Cargo.toml` — workspace membership and the `exclude` rationale.
