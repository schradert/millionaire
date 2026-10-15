# Runs on a tailnet host, piped over ssh by `android` (devenv.nix) inside a
# `nix shell` with adb and nmap. Finds the phone's wireless-debugging port,
# connects with this host's paired adb key and prints the device state as
# `key value` lines. When `link` is set (prepended by the caller), it also
# opens that Obtainium import on the phone, which asks for confirmation.
main() {
  set -euo pipefail
  local host=$1 ip serial="" port
  ip=$(tailscale ip -4 "$host")
  serial=$(adb devices </dev/null | awk -v p="$ip:" 'index($1, p) == 1 && $2 == "device" {print $1; exit}')
  if [ -z "$serial" ]; then
    # the TLS port is random per boot (Android 11+)
    for port in $(nmap -Pn -T4 --min-rate 2000 -p 5555,30000-49999 --open -oG - "$ip" </dev/null | grep -o '[0-9]*/open' | cut -d/ -f1); do
      if adb connect "$ip:$port" </dev/null | grep -Eq '^(connected|already)'; then
        serial=$ip:$port
        break
      fi
    done
  fi
  if [ -z "$serial" ]; then
    echo "error $host ($ip): no adb port; turn on Developer options > Wireless debugging" >&2
    return 3
  fi
  a() { adb -s "$serial" "$@" </dev/null; }
  echo "serial $serial"
  echo "release $(a shell getprop ro.build.version.release)"
  echo "vpn_app $(a shell settings get secure always_on_vpn_app)"
  echo "vpn_lockdown $(a shell settings get secure always_on_vpn_lockdown)"
  a shell pm list packages -3 -i | sed -n 's/^package:\([^ ]*\) *installer=\(.*\)$/pkg \1 \2/p'
  if [ -n "${link:-}" ]; then
    # via stdin: the link can exceed adb's command-line limit
    printf '%s' "$link" | adb -s "$serial" shell 'am start -a android.intent.action.VIEW -d "$(cat)"' >/dev/null
    echo "opened import"
  fi
}
main "$@"
