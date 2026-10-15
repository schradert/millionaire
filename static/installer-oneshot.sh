#!/usr/bin/env bash
# Run as root on axolotl (old NixOS, systemd-boot): boot the nixos-anywhere
# installer once from the ESP instead of kexec (kexec leaves its e1000e dead).
# Same payload as nixos-images' kexec/run: ssh keys, host keys, network state.
set -euo pipefail
SRC=/root/installer/kexec          # bzImage, initrd, run (from the nixos-images tarball)
ESP=$(bootctl --print-esp-path)
INIT=$(grep -o '^init="[^"]*"' "$SRC/run" | cut -d'"' -f2)
PARAMS=$(grep -o '^kernelParams="[^"]*"' "$SRC/run" | cut -d'"' -f2)

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$TMP"; mkdir ssh
for f in /root/.ssh/authorized_keys /etc/ssh/authorized_keys.d/root /etc/ssh/authorized_keys.d/tristan /home/tristan/.ssh/authorized_keys; do
  [ -e "$f" ] && grep -o '\(\(ssh\|ecdsa\|sk\)-[^ ]* .*\)' "$f" >> ssh/authorized_keys || true
done
[ -s ssh/authorized_keys ] || { echo "no authorized keys found" >&2; exit 1; }
cp -a /etc/ssh/ssh_host_* ssh/
ip --json addr > addrs.json
ip -4 --json route > routes-v4.json
ip -6 --json route > routes-v6.json
cp /etc/machine-id machine-id
mkdir -p "$ESP/installer"
find . | cpio -o -H newc --quiet | gzip -9 > "$ESP/installer/extra.gz"
cp "$SRC/bzImage" "$SRC/initrd" "$ESP/installer/"
cat > "$ESP/loader/entries/zz-installer.conf" <<EOF
title nixos-anywhere installer
linux /installer/bzImage
initrd /installer/initrd
initrd /installer/extra.gz
options init=$INIT $PARAMS
EOF
bootctl set-oneshot zz-installer.conf
df -h "$ESP" | tail -1
echo "oneshot armed; reboot to enter the installer"
