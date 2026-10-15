#!/usr/bin/env bash
# End-to-end OTA test on falcon's ESP32-C3 (e178): USB-flash v1, then OTA
# through good / panicking / never-healthy / corrupt images and check each one
# lands or rolls back. Builds + serial run on falcon (bin/ota-falcon.sh); WiFi
# creds come from Bitwarden like deploy-s3-wifi. See docs/iot-ota.md.
#
# Usage: ota-test [scenario ...]   (default: all, in order)
#   scenarios: flash good panic nohealth corrupt recover
# Env: OTA_REMOTE_DIR (falcon checkout, default ~/Projects/millionaire)
#      OTA_SSH_OPTS   (default: -J tristan@192.184.168.248)
set -euo pipefail

ROOT="${DEVENV_ROOT:-$PWD}"
REPO="$(cd "$ROOT/.." && pwd)"
FALCON="tristan@192.168.50.215"
REMOTE_DIR="${OTA_REMOTE_DIR:-Projects/millionaire}"
read -r -a SSH_OPTS <<<"${OTA_SSH_OPTS:--J tristan@192.184.168.248}"
RUN_ID="${OTA_RUN_ID:-$(date +%H%M%S)}"
LOG="$(mktemp -d)/ota-test.log"

echo "[ota-test] fetching wifi creds from Bitwarden Secrets Manager..."
read -r SSID_B64 PASS_B64 < <(direnv exec "$REPO" bash -c '
  set -euo pipefail
  json="$(bws secret list -o json)"
  ssid="$(printf "%s" "$json" | jq -er ".[] | select(.key==\"wifi/ssid\")     | .value")"
  pass="$(printf "%s" "$json" | jq -er ".[] | select(.key==\"wifi/password\") | .value")"
  printf "%s %s\n" "$(printf "%s" "$ssid" | base64 | tr -d "\n")" "$(printf "%s" "$pass" | base64 | tr -d "\n")"
' 2>/dev/null)

# remote ARGS... — run bin/ota-falcon.sh on falcon with the creds in its env
# (inside the SSH channel only, as in deploy-s3-wifi).
remote() {
  ssh "${SSH_OPTS[@]}" "$FALCON" 'bash -s' <<REMOTE
set -euo pipefail
export WIFI_SSID="\$(printf %s $SSID_B64 | base64 -d)"
export WIFI_PASSWORD="\$(printf %s $PASS_B64 | base64 -d)"
cd ~/$REMOTE_DIR/embedded
bash bin/ota-falcon.sh $(printf '%q ' "$@")
REMOTE
}

# expect SECS FINAL_REGEX [REGEX...] — watch serial until FINAL_REGEX, then
# require every other REGEX to have appeared in that window.
expect() {
  local secs="$1" final="$2"
  shift 2
  if ! remote watch "$secs" "$final" | tee "$LOG"; then
    echo "[ota-test] FAIL: timed out waiting for /$final/" >&2
    return 1
  fi
  for re in "$@"; do
    grep -Eq "$re" "$LOG" || {
      echo "[ota-test] FAIL: missing /$re/" >&2
      return 1
    }
  done
}

v() { echo "t$RUN_ID-$1"; }

scenario_flash() {
  remote serve
  remote build "$(v 1)" >/dev/null
  remote publish "$(v 1)"
  remote flash "$(v 1)"
  expect 600 "up to date \\($(v 1)\\)"
}
scenario_good() {
  remote build "$(v 2)" >/dev/null
  remote publish "$(v 2)"
  expect 600 "$(v 2) confirmed VALID" "$(v 1) -> $(v 2)" "trial boot of $(v 2)"
}
scenario_panic() {
  remote build "$(v 3)" panic >/dev/null
  remote publish "$(v 3)"
  expect 900 "$(v 3) previously rolled back" \
    "$(v 2) -> $(v 3)" "OTA_FAULT=panic" "never confirmed, rolling back" "version $(v 2),"
}
scenario_nohealth() {
  remote build "$(v 4)" nohealth >/dev/null
  remote publish "$(v 4)"
  expect 900 "$(v 4) previously rolled back" \
    "trial boot of $(v 4)" "trial not confirmed in time" "version $(v 2),"
}
scenario_corrupt() {
  remote build "$(v 5)" >/dev/null
  remote publish "$(v 5)" corrupt
  expect 600 "sha256 mismatch"
  # still on the good image, no reboot happened
  expect 60 "ota: (up to date|poll failed)"
}
scenario_recover() {
  remote build "$(v 6)" >/dev/null
  remote publish "$(v 6)"
  expect 600 "$(v 6) confirmed VALID" "$(v 2) -> $(v 6)" "trial boot of $(v 6)"
}

SCENARIOS=("$@")
if [ ${#SCENARIOS[@]} -eq 0 ]; then SCENARIOS=(flash good panic nohealth corrupt recover); fi
for s in "${SCENARIOS[@]}"; do
  echo "[ota-test] === $s"
  "scenario_$s"
  echo "[ota-test] === $s PASS"
done
echo "[ota-test] all passed"
