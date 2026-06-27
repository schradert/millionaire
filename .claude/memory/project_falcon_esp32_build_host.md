---
name: falcon-esp32-build-host
description: falcon PC (ssh 192.168.50.215) — NixOS ESP32 build/flash host with attached dev boards
metadata:
  node_type: memory
  type: project
  originSessionId: 3d47a54e-144c-4412-b7ca-49c68253a210
---

falcon = NixOS x86_64 PC at `ssh 192.168.50.215` (user tristan, BatchMode works). 32 cores, ~62GB RAM, 230GB free, Docker 28.x (tristan in docker group), nix-ld enabled, passwordless sudo.

Attached dev boards (as of 2026-06-10):
- 3× ESP32-C3 (4MB flash) on native USB-JTAG (`usb-Espressif_USB_JTAG_serial_debug_unit_E8:F6:0A:16:*`)
- 2× ESP32-S3 (8MB flash) on CP2102N UART bridges
- Arduino Uno, STM32 STLink, CH340 — unrelated, don't touch

Serial ports are root:dialout and tristan is NOT in dialout — esptool/flash/monitor need sudo. ESP-IDF builds work via `espressif/idf` Docker images; PlatformIO via python:3.12-slim + pip (NixOS can't run PIO's downloaded toolchains without nix-ld). ESP32 feasibility build artifacts under `/tmp/esp-feas/` there.

Key results (full writeup: docs/ereader-opds.md in repo): MicroLink (Tailscale) builds for ESP32-C3 (first known C3 build, no-PSRAM profile, 1.1MB flash / 113KB static DRAM) but its 128KB contiguous MapResponse heap spike can't coexist with crosspoint-reader on the Xteink X4; esp32-tailbridge (plain WireGuard + Linux proxy) is ~26KB flash / ~2KB RAM and same pioarduino toolchain as crosspoint. crosspoint-reader mainline already ships an OPDS browser.
