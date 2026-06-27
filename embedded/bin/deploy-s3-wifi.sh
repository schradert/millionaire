#!/usr/bin/env bash
# Deploy the WiFi `web-request` firmware to an ESP32-S3, injecting WiFi creds
# at *deploy time*.
#
# Secrets mechanism: the WiFi credentials live in Bitwarden Secrets Manager
# (keys `wifi/ssid` and `wifi/password`, matching the repo's `service/key`
# convention used for pulumi/access_token, cloudflare/api_token, etc.). They
# are fetched HERE on the dev machine via the locally-authenticated `bws` CLI
# (the root devenv's enterShell exports BWS_ACCESS_TOKEN), then piped to
# falcon's build over the SSH channel. They land only in the remote build
# process's environment — never on falcon's command line (ps), never on
# falcon's disk, never in git. The compiled firmware naturally embeds them
# (as any WiFi firmware must), but the secret itself is not persisted anywhere
# else. deploy-rs can't do this (it doesn't forward env into the remote
# build), so cred-bearing boards use this command instead of `deploy`.
#
# Usage: deploy-s3-wifi [<by-id serial port on falcon>]
#   default port = esp32-s3-cp2102n-a
set -euo pipefail

ROOT="${DEVENV_ROOT:-$PWD}"          # embedded/
REPO="$(cd "$ROOT/.." && pwd)"       # repo root (root devenv has bws + BWS_ACCESS_TOKEN)
BASTION="tristan@192.184.168.248"
FALCON="tristan@192.168.50.215"

PORT="${1:-/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7670d5c4e3cfec11a5bb1e2686bdcd52-if00-port0}"

# Fetch from Bitwarden Secrets Manager via the repo-root devenv (which provides
# `bws` + `jq` and exports BWS_ACCESS_TOKEN at enterShell). One `bws secret
# list` call; values are base64-encoded for transport so SSIDs/passwords with
# spaces or shell metacharacters survive intact (base64 has no whitespace, and
# macOS `base64` emits a single line).
echo "[deploy-s3-wifi] fetching wifi/ssid + wifi/password from Bitwarden Secrets Manager..."
read -r SSID_B64 PASS_B64 < <(direnv exec "$REPO" bash -c '
  set -euo pipefail
  json="$(bws secret list -o json)"
  ssid="$(printf "%s" "$json" | jq -er ".[] | select(.key==\"wifi/ssid\")     | .value")"
  pass="$(printf "%s" "$json" | jq -er ".[] | select(.key==\"wifi/password\") | .value")"
  printf "%s %s\n" "$(printf "%s" "$ssid" | base64)" "$(printf "%s" "$pass" | base64)"
')
SSID="$(printf '%s' "$SSID_B64" | base64 -d)"
PASS="$(printf '%s' "$PASS_B64" | base64 -d)"
[ -n "$SSID" ] || { echo "error: wifi/ssid not found in Bitwarden Secrets Manager" >&2; exit 1; }
echo "[deploy-s3-wifi] SSID '$SSID' — building on falcon and flashing $PORT"

# Creds are shell-quoted on THIS machine (printf %q) and interpolated into the
# piped script, so they travel inside the SSH channel and end up only in the
# remote shell's env. `touch main.rs` forces rustc to re-evaluate env!() (cargo
# does not track env-var value changes), so the real creds get baked in.
ssh -J "$BASTION" "$FALCON" 'bash -s' <<REMOTE
set -euo pipefail
export WIFI_SSID=$(printf %q "$SSID")
export WIFI_PASSWORD=$(printf %q "$PASS")
cd ~/Projects/millionaire/embedded
touch boards/esp32-s3/src/main.rs
(cd boards/esp32-s3 && direnv exec . cargo build --release) >&2
ESPFLASH=\$(direnv exec . which espflash)
sudo -n "\$ESPFLASH" flash --chip esp32s3 --port "$PORT" \
  target/xtensa-esp32s3-none-elf/release/homelab-esp32-s3
REMOTE

echo "[deploy-s3-wifi] flashed. Monitor with:"
echo "  ssh -J $BASTION $FALCON \"direnv exec ~/Projects/millionaire/embedded espflash monitor --port $PORT\""
