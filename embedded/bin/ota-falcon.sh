#!/usr/bin/env bash
# OTA test helper for the ESP32-C3 PoC. Runs ON falcon, from the embedded/ dir
# of a repo checkout. Driven by bin/ota-test.sh (which injects WIFI_SSID /
# WIFI_PASSWORD from Bitwarden over SSH); see docs/iot-ota.md.
#
#   ota-falcon.sh build   VERSION [FAULT]   build + save app image to $WWW
#   ota-falcon.sh flash   VERSION           USB-flash VERSION into ota_0, reset otadata
#   ota-falcon.sh publish VERSION [corrupt] point the manifest at VERSION
#   ota-falcon.sh serve                     start the HTTP server (idempotent)
#   ota-falcon.sh watch   SECS REGEX        tail serial until REGEX or timeout
set -euo pipefail

BOARD=esp32-c3
PORT="${OTA_PORT:-/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_E8:F6:0A:16:E1:78-if00}"
WWW="${OTA_WWW:-/tmp/ota-www}"
HOST="${OTA_HOST:-192.168.50.215}"
HTTP_PORT="${OTA_HTTP_PORT:-8070}"
ELF=target/riscv32imc-unknown-none-elf/release/homelab-esp32-c3
SUDO=/run/wrappers/bin/sudo

cd "$(dirname "$0")/.."
mkdir -p "$WWW/$BOARD"
tool() { direnv exec . which "$1" 2>/dev/null; }

case "$1" in
build)
  export OTA_VERSION="$2" OTA_URL="http://$HOST:$HTTP_PORT"
  if [ -n "${3:-}" ]; then export OTA_FAULT="$3"; else unset OTA_FAULT; fi
  touch "boards/$BOARD/src/main.rs"
  (cd "boards/$BOARD" && direnv exec . cargo build --release) >&2
  "$(tool espflash)" save-image --chip esp32c3 "$ELF" "$WWW/$BOARD/$2.bin" >&2
  cp "$ELF" "$WWW/$BOARD/$2.elf"
  ls -l "$WWW/$BOARD/$2.bin"
  ;;
flash)
  "$SUDO" -n "$(tool espflash)" flash --chip esp32c3 --port "$PORT" \
    --partition-table "boards/$BOARD/partitions.csv" \
    --target-app-partition ota_0 --erase-parts otadata \
    "$WWW/$BOARD/$2.elf"
  ;;
publish)
  bin="$WWW/$BOARD/$2.bin"
  sha=$(sha256sum "$bin" | cut -d' ' -f1)
  if [ "${3:-}" = corrupt ]; then sha=$(printf '0%.0s' {1..64}); fi
  echo "$2 $sha $(stat -c %s "$bin")" >"$WWW/$BOARD/manifest.tmp"
  mv "$WWW/$BOARD/manifest.tmp" "$WWW/$BOARD/manifest"
  cat "$WWW/$BOARD/manifest"
  ;;
serve)
  if ! curl -sf -o /dev/null "http://$HOST:$HTTP_PORT/$BOARD/manifest" && ! ss -ltn | grep -q ":$HTTP_PORT "; then
    (nohup python3 -m http.server "$HTTP_PORT" --bind "$HOST" --directory "$WWW" \
      >/tmp/ota-www.log 2>&1 &)
    sleep 1
  fi
  echo "serving $WWW on http://$HOST:$HTTP_PORT"
  ;;
watch)
  "$SUDO" -n stty -F "$PORT" 115200 raw -echo
  # Print every line; exit 0 on the first line matching REGEX, 1 on timeout.
  set +o pipefail
  # (no `tr` in the pipe: it block-buffers, delaying matches until timeout)
  "$SUDO" -n timeout "$2" cat "$PORT" | {
    while IFS= read -r line; do
      line="${line%$'\r'}"
      printf '%s\n' "$line"
      if [[ "$line" =~ $3 ]]; then exit 0; fi
    done
    exit 1
  }
  ;;
*)
  sed -n '2,12p' "$0"
  exit 2
  ;;
esac
