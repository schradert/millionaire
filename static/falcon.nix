## Falcon — the x86_64-linux box with all the microcontrollers plugged in.
#
# Defined as a canivete.deploy node with profiles for each physically-
# present microcontroller. Each profile is `canivete.type = "custom"`, which
# maps onto deploy-rs's `activate.custom`. The activation derivation is a
# tiny `writeShellApplication` that:
#
#   1. Checks whether the device is reachable on falcon. If not, prints
#      "skipping" and exits 0. The overall `deploy` doesn't fail.
#   2. cd's into the embedded workspace on falcon (canonical path:
#      `~/Projects/millionaire/embedded`), builds the per-board cargo crate
#      via `direnv exec . cargo build --release`, and flashes with the
#      right tool (espflash / probe-rs / teensy-loader-cli / ravedude).
#
# Assumes the embedded/ source is already at `~/Projects/millionaire/embedded`
# on falcon — keep it in sync via rsync or git pull. (A future improvement
# is to make the firmware a real Nix derivation and embed it in the
# activation closure; for now the script does a remote cargo build.)
#
# Notes
#  * `magicRollback = false` because there is no "service" to ping back
#    after a flash; the firmware just runs.
#  * `remoteBuild = true` because falcon is x86_64-linux and dev hosts are
#    aarch64-darwin — building locally means going through the
#    `nix.linux-builder` VM, which is slow to spin up for what is otherwise
#    a tiny closure. Falcon builds its own activation natively.
{
  hostname = "192.168.50.215";
  sshUser = "tristan";
  # falcon lives on the home LAN. From off-LAN dev hosts, jump through the
  # edge box at 192.184.168.248 (same user). Unconditional ProxyJump — on-LAN
  # the extra hop costs a few ms; off-LAN it's the only route. deploy-rs
  # forwards these opts to both raw ssh and the `nix copy --to ssh-ng://`
  # build step via NIX_SSHOPTS.
  #
  # ControlMaster: a full-manifest deploy fires off ~20 sequential SSH
  # sessions (per profile: nix copy --derivation, nix build, then the
  # activate-rs invocation). Opening a fresh TCP+SSH+ProxyJump handshake
  # each time stresses the bastion enough that it'll drop connections
  # mid-deploy. Multiplexing through one persistent control socket keeps
  # the whole deploy on a single underlying tunnel.
  sshOpts = [
    "-J"
    "tristan@192.184.168.248"
    "-o"
    "ControlMaster=auto"
    "-o"
    "ControlPath=~/.ssh/cm-%r@%h:%p"
    "-o"
    "ControlPersist=600"
  ];
  fastConnection = true;
  magicRollback = false;
  autoRollback = false;
  # Build the activation closure on falcon itself. falcon is x86_64-linux
  # native, so this avoids spinning up the macOS linux-builder VM for what
  # is otherwise a near-empty (direnv/sudo/coreutils/grep) closure that
  # falcon's substituters will likely have cached already.
  remoteBuild = true;

  profiles = let
    # Where the embedded workspace lives on falcon. The activation script
    # cd's here and runs cargo via direnv. Keep in sync between local and
    # falcon (rsync, git pull, etc.). The double-quoting at the Nix level
    # means each use-site emits a quoted shell literal, satisfying shellcheck
    # (SC2086) without needing per-call quoting.
    embeddedDir = ''"$HOME/Projects/millionaire/embedded"'';

    # Per-platform target triple and crate name. Drives the binary path
    # cargo writes to, and which flash tool to invoke.
    targetTriple = platform:
      {
        "esp32-c3" = "riscv32imc-unknown-none-elf";
        "esp32-s3" = "xtensa-esp32s3-none-elf";
        "stm32-nucleo" = "thumbv7em-none-eabihf";
        "teensy-4.1" = "thumbv7em-none-eabihf";
        "arduino-uno-r3" = "avr-none";
      }.${
        platform
      };
    crateName = platform:
      {
        "esp32-c3" = "homelab-esp32-c3";
        "esp32-s3" = "homelab-esp32-s3";
        "stm32-nucleo" = "homelab-stm32-nucleo";
        "teensy-4.1" = "homelab-teensy-4-1";
        "arduino-uno-r3" = "homelab-arduino-uno-r3";
      }.${
        platform
      };

    # Manifest of physical boards. Note: ESP32-S3 #4 (USB serial 4e4708fe…)
    # is intentionally omitted — its previous owner locked flash encryption
    # + secure boot, can never run unsigned firmware again.
    boards = {
      "esp32-s3-lonely-binary-n16r8" = {
        platform = "esp32-s3";
        usbSerial = "usb-1a86_USB_Serial-if00-port0";
        notes = "Lonely Binary N16R8 (16 MB flash, 8 MB PSRAM). CH343 USB-UART.";
      };
      "esp32-s3-cp2102n-a" = {
        platform = "esp32-s3";
        usbSerial = "usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7670d5c4e3cfec11a5bb1e2686bdcd52-if00-port0";
      };
      "esp32-s3-cp2102n-b-recovered" = {
        platform = "esp32-s3";
        usbSerial = "usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_427784b59821ec11a824be942c86906c-if00-port0";
        mac = "f4:12:fa:57:1e:90";
        notes = "Recovered 2026-05-26 via SPI_BOOT_CRYPT_CNT eFuse burn (0b001 → 0b011, encryption disabled).";
      };

      "esp32-c3-e178" = {
        platform = "esp32-c3";
        usbSerial = "usb-Espressif_USB_JTAG_serial_debug_unit_E8:F6:0A:16:E1:78-if00";
        mac = "e8:f6:0a:16:e1:78";
      };
      "esp32-c3-fa14" = {
        platform = "esp32-c3";
        usbSerial = "usb-Espressif_USB_JTAG_serial_debug_unit_E8:F6:0A:16:FA:14-if00";
        mac = "e8:f6:0a:16:fa:14";
      };
      "esp32-c3-da60" = {
        platform = "esp32-c3";
        usbSerial = "usb-Espressif_USB_JTAG_serial_debug_unit_E8:F6:0A:16:DA:60-if00";
        mac = "e8:f6:0a:16:da:60";
      };

      "arduino-uno-r3" = {
        platform = "arduino-uno-r3";
        usbSerial = "usb-Arduino__www.arduino.cc__0043_142353038353511061C0-if00";
      };

      "stm32-nucleo-f446re" = {
        platform = "stm32-nucleo";
        probeSelector = "0483:374b";
        notes = "Nucleo-F446RE. Update embedded/boards/stm32-nucleo/Cargo.toml chip feature + memory.x if you swap MCUs.";
      };

      "teensy-4-1" = {
        platform = "teensy-4.1";
        notes = "Press the white button to enter HalfKay before deploy; 10s timeout then skipped.";
      };
    };

    # NixOS wraps setuid binaries under /run/wrappers/bin. The sudo from a
    # nix-store path lacks the setuid bit (the store is read-only and
    # content-addressed, so no setuid is possible), so any `sudo` we pull in
    # via writeShellApplication's runtimeInputs would fail with
    # "must be owned by uid 0 and have the setuid bit set". Hardcode the
    # wrapper path — this is falcon-specific (NixOS) anyway.
    sudo = "/run/wrappers/bin/sudo";

    # Per-platform activation body. The script's PATH is set by
    # writeShellApplication's runtimeInputs (direnv, coreutils, grep); the
    # flash tools come from the embedded/ devenv via `direnv exec`, and sudo
    # is invoked by absolute path (see above).
    activationBody = name: cfg: let
      platform = cfg.platform;
      triple = targetTriple platform;
      crate = crateName platform;
      workspaceBin = "target/${triple}/release/${crate}";
      arduinoBin = "boards/arduino-uno-r3/target/${triple}/release/${crate}.elf";
    in
      if platform == "esp32-c3" || platform == "esp32-s3"
      then let
        chip = builtins.replaceStrings ["-"] [""] platform;
      in ''
        PORT="/dev/serial/by-id/${cfg.usbSerial}"
        if [ ! -e "$PORT" ]; then
          echo "[${name}] not connected at $PORT, skipping"; exit 0
        fi
        cd ${embeddedDir}
        echo "[${name}] building"
        (cd boards/${platform} && direnv exec . cargo build --release) >&2
        ESPFLASH=$(direnv exec . which espflash)
        echo "[${name}] flashing via $PORT"
        ${sudo} -n "$ESPFLASH" flash --chip ${chip} --port "$PORT" ${workspaceBin}
        echo "[${name}] flashed"
      ''
      else if platform == "arduino-uno-r3"
      then ''
        PORT="/dev/serial/by-id/${cfg.usbSerial}"
        if [ ! -e "$PORT" ]; then
          echo "[${name}] not connected at $PORT, skipping"; exit 0
        fi
        # ravedude has a hang-on-failure bug: when avrdude can't sync with the
        # bootloader, ravedude spins at 100% CPU forever instead of erroring
        # out, *and* it keeps the serial port open — blocking every subsequent
        # flash attempt with "Resource temporarily unavailable". Kill any
        # stragglers from a previous failed run before we start.
        ${sudo} -n pkill -9 -f ravedude 2>/dev/null || true
        ${sudo} -n pkill -9 -f avrdude  2>/dev/null || true
        cd ${embeddedDir}
        echo "[${name}] building (AVR nightly via boards/arduino-uno-r3/.envrc)"
        (cd boards/arduino-uno-r3 && direnv exec . cargo build --release) >&2
        # ravedude shells out to avrdude + avr-gcc, so we can't just resolve
        # ravedude's path and run it under bare sudo (sudo strips PATH, those
        # tools become unfindable). Instead, capture the AVR devenv's full PATH
        # and inject it via `sudo env PATH=...`. Other flash tools (espflash,
        # probe-rs, teensy-loader-cli) are self-contained binaries and don't
        # need this dance.
        #
        # Note: no `-cb <baud>` flag here on purpose. That option tells ravedude
        # to open a serial monitor after flashing, which would never exit on
        # its own — perfect for `cargo run`, fatal for a deploy script. Without
        # `-cb`, ravedude flashes and exits.
        RAVEDUDE=$(cd boards/arduino-uno-r3 && direnv exec . which ravedude)
        AVR_PATH=$(cd boards/arduino-uno-r3 && direnv exec . printenv PATH)
        echo "[${name}] flashing via $PORT (60s timeout — if auto-reset isn't working, press the UNO reset button now)"
        # Best-effort flash: if avrdude can't sync within 60s (~10× its default
        # retry budget), give up rather than blocking the rest of the manifest.
        # The deploy still exits 0 so other boards keep flashing.
        if timeout 60 ${sudo} -n env "PATH=$AVR_PATH" "$RAVEDUDE" uno -P "$PORT" ${arduinoBin}; then
          echo "[${name}] flashed"
        else
          echo "[${name}] flash failed or timed out; auto-reset may be flaky — try again and press the reset button as the deploy starts. Continuing."
          # Clean up any stuck ravedude before we exit so the next deploy has
          # a free port.
          ${sudo} -n pkill -9 -f ravedude 2>/dev/null || true
          ${sudo} -n pkill -9 -f avrdude  2>/dev/null || true
        fi
      ''
      else if platform == "stm32-nucleo"
      then ''
        # Match the specific probe: `probe-rs list` prints "No debug probes
        # were found." (non-empty!) when nothing is attached, so grepping for
        # any output would never take the skip path.
        if ! direnv exec ${embeddedDir} probe-rs list 2>/dev/null | grep -q '${cfg.probeSelector}'; then
          echo "[${name}] no debug probe detected, skipping"; exit 0
        fi
        cd ${embeddedDir}
        echo "[${name}] building"
        (cd boards/stm32-nucleo && direnv exec . cargo build --release) >&2
        PROBE_RS=$(direnv exec . which probe-rs)
        echo "[${name}] flashing via probe-rs"
        # `download` + `reset` rather than `run`, so we don't hold RTT open
        ${sudo} -n "$PROBE_RS" download --chip STM32F446RETx --probe ${cfg.probeSelector} ${workspaceBin}
        ${sudo} -n "$PROBE_RS" reset    --chip STM32F446RETx --probe ${cfg.probeSelector}
        echo "[${name}] flashed"
      ''
      else if platform == "teensy-4.1"
      then ''
        cd ${embeddedDir}
        echo "[${name}] building"
        (cd boards/teensy-4.1 && direnv exec . cargo build --release) >&2
        OBJCOPY=$(direnv exec . which llvm-objcopy)
        TLC=$(direnv exec . which teensy-loader-cli)
        "$OBJCOPY" -O ihex ${workspaceBin} ${workspaceBin}.hex
        echo "[${name}] press the Teensy white button (10s window)"
        if timeout 10 ${sudo} -n "$TLC" --mcu=TEENSY41 -w -v ${workspaceBin}.hex 2>&1; then
          echo "[${name}] flashed"
        else
          echo "[${name}] no HalfKay button press in 10s, skipping"
        fi
      ''
      else throw "falcon.nix: unsupported platform ${platform}";

    # Profile module. We override `path` directly rather than going through
    # canivete's `canivete.configuration` + `canivete.activator` plumbing,
    # because canivete's `custom`-type activator default has a bug — it tries
    # to read `base.canivete.activationPackage` on the result of `lib.evalModules`,
    # but evalModules puts option values under `base.config.*`. Setting `path`
    # directly is also simpler: no need to round-trip a derivation through an
    # extra option just to read it back out.
    mkProfile = name: cfg: {
      flake,
      node,
      lib,
      ...
    }:
      flake.withSystem node.config.canivete.system ({pkgs, ...}: let
        inherit (flake.config.canivete.deploy.canivete.flakes.deploy.lib.${node.config.canivete.system}) activate;
        activationDrv = pkgs.writeShellApplication {
          name = "flash-${name}";
          # PATH inside the script. Actual flash tools come from the
          # embedded/ devenv via `direnv exec`. Note: sudo is *not* in this
          # list — see the `sudo = "/run/wrappers/bin/sudo"` binding above
          # for why we go through NixOS's setuid wrapper directly.
          runtimeInputs = with pkgs; [direnv coreutils gnugrep];
          text = ''
            set -euo pipefail
            ${activationBody name cfg}
          '';
        };
      in {
        canivete.type = "custom";
        path = activate.custom activationDrv (lib.getExe activationDrv);
      });
  in
    builtins.mapAttrs mkProfile boards;
}
