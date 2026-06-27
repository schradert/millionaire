{
  inputs,
  pkgs,
  lib,
  ...
}: let
  system = pkgs.stdenv.hostPlatform.system;
  espSrc = inputs.esp-rs-nix;
  espNix = espSrc.packages.${system};

  # ── Workaround for leighleighleigh/esp-rs-nix#19 ────────────────────────
  # On aarch64-darwin, every sub-derivation in esp-rs-nix (esp-{xtensa,riscv32}-
  # gcc, esp-{xtensa,riscv32}-gdb, esp-rust-build, and the final rust-src.nix
  # combiner) unconditionally pulls in autoPatchelfHook, which trips on the
  # Mach-O binaries inside Espressif's Darwin tarballs. Strip the hook from
  # every sub-package on Darwin and re-derive esp-rs from upstream's
  # rust-src.nix. On Linux this is a no-op.
  removeAutoPatch = pkg:
    pkg.overrideAttrs (old: {
      nativeBuildInputs = builtins.filter
        (p: !(lib.hasInfix "auto-patchelf" (p.name or "")))
        (old.nativeBuildInputs or []);
    });

  esp-rs =
    if pkgs.stdenv.isDarwin
    then
      removeAutoPatch (pkgs.callPackage "${espSrc}/esp-rs/rust-src.nix" {
        version = espNix.esp-rust-build.version or "1.93.0.0";
        esp-rust-build = removeAutoPatch espNix.esp-rust-build;
        esp-xtensa-gcc = removeAutoPatch espNix.esp-xtensa-gcc;
        esp-xtensa-gdb = removeAutoPatch espNix.esp-xtensa-gdb;
        esp-riscv32-gcc = removeAutoPatch espNix.esp-riscv32-gcc;
        esp-riscv32-gdb = removeAutoPatch espNix.esp-riscv32-gdb;
      })
    else espNix.esp-rs;

  # ── AVR toolchain (Arduino Uno R3) ──────────────────────────────────────
  # The esp-rs toolchain lacks the AVR LLVM backend; can't compile for AVR
  # at all. So we ship a SEPARATE upstream-nightly toolchain just for the
  # arduino-uno-r3 crate, pinned to the avr-hal-template's known-good date
  # (AVR backend regressions in nightly are common, and avr-hal pins to a
  # specific date that's been tested).
  #
  # This isn't put on PATH at the workspace level — that would shadow esp-rs.
  # Instead the path is exposed via env.AVR_RUST so that
  # `boards/arduino-uno-r3/.envrc` can prepend it to PATH for that subdir only.
  pkgs-rust = pkgs.appendOverlays [inputs.rust-overlay.overlays.default];
  avr-rust = pkgs-rust.rust-bin.nightly."2025-04-27".default.override {
    extensions = ["rust-src"];
  };

  # ── Upstream nightly toolchain (cross-build the non-Xtensa boards locally) ──
  # The esp-rs fork builds everything on falcon, but on macOS its build-std +
  # host build-deps (esp-config → hashbrown/allocator-api2) don't compile. The
  # RISC-V (C3) and Cortex-M (STM32/Teensy) targets, however, are *upstream*
  # Rust targets: a plain upstream nightly with `rust-src` can build-std core/
  # alloc for them from source on any host, including Darwin. So we ship an
  # upstream nightly too, selected per-invocation via the `xcargo` wrapper
  # (below). esp-rs stays the default — Xtensa (S3) is upstream-unsupported and
  # the falcon/deploy flow is unchanged (backwards compatible). `latest` keeps
  # it close to esp-rs's own nightly; pin a date here if reproducibility bites.
  upstream-rust = pkgs-rust.rust-bin.selectLatestNightlyWith (t:
    t.default.override {
      extensions = ["rust-src"];
    });

  # TODO expose these some other way upstream
  caniveteModules = let
    any = builtins.head (builtins.attrNames inputs.canivete.canivete);
  in
    inputs.canivete.canivete.${any}.devenv.modules;
in {
  imports = caniveteModules;

  # ─── Default Rust toolchain (esp-rs) ────────────────────────────────────
  # The esp-rs toolchain is an Espressif fork based on nightly Rust that
  # bundles support for:
  #   - Xtensa (ESP32-S3) — not in upstream
  #   - RISC-V (ESP32-C3, C6, etc.) — `riscv32imc-unknown-none-elf` builtin
  #   - ARM Cortex-M (STM32, Teensy) — `thumbv*-none-eabi*` work since it's nightly
  # Arduino-Uno-R3 needs a different toolchain entirely (AVR LLVM backend);
  # see `avr-rust` above and `boards/arduino-uno-r3/.envrc`.
  languages.rust = {
    enable = true;
    toolchain = {
      rustc         = esp-rs;
      cargo         = esp-rs;
      clippy        = esp-rs;
      rustfmt       = esp-rs;
      rust-analyzer = pkgs.rust-analyzer;
    };
  };

  # Bridge to per-board .envrc: boards/arduino-uno-r3/.envrc reads this and
  # prepends it to PATH so cargo invocations under that crate find the AVR
  # toolchain instead of esp-rs.
  env.AVR_RUST = "${avr-rust}";

  # Consumed by the `xcargo` wrapper to run cargo with the upstream nightly
  # toolchain (local cross-builds of the non-Xtensa boards). See above + xcargo.
  env.UPSTREAM_RUST = "${upstream-rust}";

  packages = with pkgs; [
    # ─── ESP family ────────────────────────────────────────────────────
    espflash         # flash + monitor for all ESP32 variants
    esp-generate     # project templates
    esptool          # provides espefuse for eFuse inspection / burning

    # ─── Cortex-M (STM32, Teensy) ──────────────────────────────────────
    probe-rs-tools   # flash + RTT + GDB for any Cortex-M with SWD/JTAG
    cargo-binutils   # `cargo objcopy`, needed by Teensy flash flow
    flip-link        # stack-overflow safe linker for Cortex-M

    # ─── Teensy 4.x ────────────────────────────────────────────────────
    teensy-loader-cli
    llvmPackages.bintools  # llvm-objcopy for ARM ELF → Intel HEX conversion

    # ─── AVR (Arduino Uno) ─────────────────────────────────────────────
    avrdude                          # the actual flash tool
    ravedude                         # cargo runner wrapping avrdude
    pkgsCross.avr.buildPackages.gcc  # avr-gcc, used for linking

    # ─── Scaffolding ───────────────────────────────────────────────────
    cargo-generate   # `cargo generate` — drives templates/ (see new-app / new-board)

    # ─── Misc cross-platform ───────────────────────────────────────────
    usbutils         # lsusb for debugging connections
  ];

  # ─── Scaffolding commands ───────────────────────────────────────────────
  # Thin wrappers over cargo-generate (templates/) that also handle workspace
  # bookkeeping. The logic lives in committed shell scripts so it's testable
  # outside Nix; these just run them inside the dev shell. See templates/.
  scripts.new-app.exec = ''exec bash "$DEVENV_ROOT/templates/bin/new-app.sh" "$@"'';
  scripts.new-board.exec = ''exec bash "$DEVENV_ROOT/templates/bin/new-board.sh" "$@"'';
  scripts.new-shared.exec = ''exec bash "$DEVENV_ROOT/templates/bin/new-shared.sh" "$@"'';

  # Deploy a build-time-secret-bearing board (the WiFi web-request S3) by
  # fetching creds from Bitwarden Secrets Manager via `bws` and injecting them
  # into falcon's build over SSH. See bin/deploy-s3-wifi.sh and TARGETS.md.
  scripts.deploy-s3-wifi.exec = ''exec bash "$DEVENV_ROOT/bin/deploy-s3-wifi.sh" "$@"'';

  # `check` — the embedded CI: compile + clippy every board for its own target
  # on falcon (where all targets, incl. esp-rs build-std, build). See bin/check.sh.
  scripts.check.exec = ''exec bash "$DEVENV_ROOT/bin/check.sh" "$@"'';

  # `fmt` — rustfmt every Rust file in the workspace (members AND the excluded
  # crates), skipping templates/ (Liquid) and target/. Per-file rustfmt picks up
  # edition from rustfmt.toml. Editor format-on-save covers the per-file case.
  scripts.fmt.exec = ''
    find "$DEVENV_ROOT" -name '*.rs' \
      -not -path '*/target/*' -not -path '*/templates/*' -print0 \
    | xargs -0 rustfmt
  '';

  # `xcargo` — run cargo with the UPSTREAM nightly toolchain instead of the
  # default esp-rs. Use it to cross-build the non-Xtensa boards locally (incl.
  # macOS): `cd boards/esp32-c3 && xcargo build --release`. The board's
  # .cargo/config (target + build-std) still applies; build-std compiles core
  # from upstream rust-src. NOT for the S3 (Xtensa is upstream-unsupported —
  # build it on falcon). Plain `cargo` is unchanged (esp-rs), so deploy/falcon
  # and the S3 keep working exactly as before.
  scripts.xcargo.exec = ''
    export PATH="$UPSTREAM_RUST/bin:$PATH"
    exec cargo "$@"
  '';

  # ─── git-hooks ──────────────────────────────────────────────────────────
  # Rust QA is deliberately NOT wired into git-hooks / treefmt here:
  #   * cargo-based `rustfmt`/`clippy` hooks can't work — git-hooks run from the
  #     repo root, which has no Cargo.toml (this workspace lives in embedded/).
  #   * treefmt's per-file rustfmt isn't used either: devenv runs treefmt on
  #     every shell entry, and rustfmt chokes on the Liquid `templates/*.rs`
  #     (excludes proved version-fragile across devenv 1.8 vs 2.0), which would
  #     break `direnv exec .` — and therefore deploy/check — on falcon.
  # So Rust formatting is via editor format-on-save (.helix/.zed) + the `fmt`
  # script, and linting/compile checks via `check` (per-board clippy on falcon).
  # treefmt still handles toml/md/nix in the hooks.
  #
  # The cargo-generate templates contain Liquid ({{ }}, {% %}) in .rs/.toml,
  # so they're not valid Rust/TOML — exclude from the file-based hooks.
  git-hooks.excludes = ["embedded/templates/.+"];

  treefmt.config.settings.formatter.dprint.options = ["--allow-no-files"];
}
