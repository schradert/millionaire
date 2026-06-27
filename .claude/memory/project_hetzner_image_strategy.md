---
name: hetzner-image-strategy
description: Hetzner x86 VMs are BIOS-only — systemd-boot never boots; use the golden-image strategy (static/hetzner-image.nix) instead of nixos-anywhere
metadata:
  node_type: memory
  type: project
  originSessionId: 9b142a34-2241-45c3-9d7d-3c51bd4421b7
---

Hetzner Cloud x86 servers (cx/cpx/ccx) boot legacy BIOS (SeaBIOS) only — no UEFI (ARM cax are UEFI). The shared disko layout (modules/disko.nix: GPT + EF00 ESP + systemd-boot) is therefore unbootable on them; this was the root cause of every nixos-anywhere install "succeeding" then never coming back after reboot (zero network traffic — firmware had no boot path).

Strategy (verified working 2026-06-10): build a minimal BIOS-GRUB golden image, upload as Hetzner snapshot, create servers from it, push real config via deploy-rs.

- Image config: `static/hetzner-image.nix` — GRUB MBR (device /dev/vda at build time inside the make-disk-image VM), ext4 by-label `nixos` with autoResize + growPartition, qemu-guest profile, DHCP, sshd + personal key.
- Flake output: `nixosConfigurations.hetzner-image`; build product `.#nixosConfigurations.hetzner-image.config.system.build.hetznerImage` (x86_64-linux only).
- Build box: falcon (`ssh -i ~/.ssh/personal tristan@192.168.50.215`), x86_64 NixOS with KVM; rsync repo to `~/millionaire-image-build`, build with `--impure`.
- Upload: `hcloud-upload-image upload --architecture x86 --compression xz --image-path <img.xz>` (in devenv; needs HCLOUD_TOKEN). Transient "request timeout" on temp-server boot happens — just retry.
- First working snapshot: image id 396268774 ("nixos-hetzner-golden-image").
- Test boot verified: SSH up in ~10s, GRUB `(hd0,msdos1)`, FS auto-grew.

Codified + verified working end-to-end (2026-06-11), keeping ZFS fleet consistency (no ext4 divergence):
- hyena keeps the shared disko ZFS layout; only diffs: `boot.loader.grub.enable` (systemd-boot mkForce'd off; disko auto-derives grub.devices from the EF02 partition — do NOT also set grub.device, that trips the mirroredBoots duplicate assertion), an EF02 1M partition, `imageSize`, and a zpool-expand oneshot (growpart + `zpool online -e` against the by-partuuid vdev name, needs gawk in path).
- Image built from hyena's own config: `.#nixosConfigurations.hyena.config.system.build.diskoImages` (disko rewrites devices + grub.devices inside its build VM automatically).
- Pipeline: `bin/build-hetzner-snapshot.sh` (rsync→falcon build→xz→scp→hcloud-upload-image; prints snapshot id) driven by pulumi `hyena-image` Command; `millionaire.NixOSImage` class = bootstrap (wait ssh + scp age key) + deploy-rs with `--remote-build --ssh-opts '-o StrictHostKeyChecking=no …' --hostname $IP`.
- Gotchas hit: headscale ≥0.26 `preauthkeys create --user` wants the numeric user id (`headscale users list -o json | jq … .id`), not the name; a year-old orphaned Cloudflare A record for headscale.trdos.me broke ACME (two A records → http-01 hit the dead IP) — pulumi only manages its own record, check for strays with the CF API when ACME mysteriously serves the minica fallback.
- Cluster deploys (sirver etc.) still fail from the Mac when LAN hostnames don't resolve (Mac doesn't use router DNS at 192.168.50.1 which does resolve them); attic/auth-token BWS secret blocked on the same. See [[pulumi-never-reinstall-cluster-nodes]] before any pulumi up.
