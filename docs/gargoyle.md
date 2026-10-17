# gargoyle (OnePlus 6)

The OnePlus 6 (`enchilada`, Snapdragon 845, serial `b56560dd`) runs NixOS as a personal client:
the client profile, the tailnet, Syncthing (the `org` folder), the calendar, the API keys, Plasma
Mobile and Waydroid for Android apps. It is not a Kubernetes node. Config: `static/gargoyle.nix`;
rescue image: `static/gargoyle-rescue.nix`; node entry: `gargoyle` in `flake.nix`.

## Route (decided 2026-10-17)

Mobile NixOS upstream (`mobile-nixos` input, non-flake, imported by device name), because it is the
only NixOS route that is maintained for this device and boots a kernel with Waydroid's requirements:

- Upstream is alive for the platform: the nixpkgs-adaptation merge #884 (2026-07-12) fixed the
  enchilada build on nixos-unstable; `oneplus-enchilada` is `supportLevel = "supported"`.
  This repo's pin (`2c132754`, 2026-07-13) evaluates and builds on falcon.
- The kernel is sdm845-mainline **6.4** (`sdm845-6.4-r1`, 2023), old but it has
  `ANDROID_BINDER_IPC`, `ANDROID_BINDERFS`, `ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"`,
  `PSI`, `TUN`, `WIREGUARD`, nftables (`devices/families/sdm845-mainline/kernel/config.aarch64`).
  No xtables rpfilter match: `networking.firewall.checkReversePath = false`.
- Newer kernels exist upstream of it (sdm845-mainline `sdm845-6.18.2-r0`, `sdm845-7.1-rc1-r0`) and
  open PRs move Mobile NixOS to them (mobile-nixos#859, #862, draft #853); none merged.

Alternatives looked at (facts as of 2026-10-17):

| Route | Kernel | enchilada status | Binder |
|---|---|---|---|
| [vanilla-mobile-nixos](https://github.com/vanilla-mobile-nixos/vanilla-mobile-nixos) (standard NixOS, U-Boot + systemd-boot) | 7.1 | "implemented but untested"; bootloop issue #28 open | unverified (binderfs looks off) |
| [MatthewCroughan/nixos-sdm845](https://github.com/MatthewCroughan/nixos-sdm845) | 7.0-rc2 (sdm845-next) | boots per commits; no status table | likely via common config |
| [fl42v/nixos-sdm845](https://github.com/fl42v/nixos-sdm845) | 6.18.2 | Wi-Fi, GPU, USB net work; modem, BT not | IPC yes, binderfs not set |
| postmarketOS / Nura (not NixOS) | 7.1-rc1 | community device, most complete | not verified for 7.1 |

If the 6.4 kernel turns out to be the blocker (Wi-Fi, GPU in Waydroid), the next step is the
sdm845-mainline 6.18 kernel through mobile-nixos#859, not a different distribution.

UI: Plasma Mobile (`profiles.desktop.plasma.mobile`). Mobile NixOS's Phosh example bootloops on
this phone (mobile-nixos#851, open), and the old plasma-mobile example was the one that booted.

## Partitions and what a flash wipes

From `fastboot getvar all` (2026-10-17): bootloader unlocked, `current-slot: a` (successful),
slot b never marked successful. `boot_a/b` 64 MiB, `system_a/b` 2.8 GiB, `userdata` 50.4 GiB
(0xC9A8BB000 bytes, the size a 64 GB unit has, not 128 GB). Mobile NixOS boots `boot` (A/B,
boot-as-recovery, no vendor_boot) and finds its root by the ext4 label `NIXOS_SYSTEM`; the system
is too large for `system_a`, so it goes to `userdata`. A flash wipes `boot_a`, `boot_b` and
`userdata` (the previous Mobile NixOS install and its home directory). Firmware partitions,
`modem`, `persist` and the bootloader are never written.
