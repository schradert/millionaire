#!/usr/bin/env bash
# Runs on a tailnet host, piped over ssh by `android` (devenv.nix) inside a
# `nix shell` with adb, nmap, curl, jq and unzip (or locally, with `dry=1`, against stubs that print what would
# run), behind static/android-reconcile.sh. Reaches the phone over one of two transports and prints the device state
# as `key value` lines. The caller prepends variables (printf %q):
#   tp      ssh | adb | auto (default): the management channel first (sshd in Termux on the tailnet, privileged
#           calls through Shizuku's rish), adb (wireless debugging, Wi-Fi only) otherwise. The audit and
#           `reconcile` use either; `channel`, `productivity` and `pair` need adb.
#   chan_key, chan_known, chan_port   the channel's ssh key (default ~/.android/ssh_key), known_hosts and port
#   from_ip bonobo's tailnet address: the only source the phone's authorized key accepts (`channel`)
#   link    opens that Obtainium import on the phone (adb), which asks for confirmation
#   spec    android.devices.<d>.productivity as JSON: adds `prod ok|DRIFT <check>` audit lines
#   st_key  Syncthing's GUI API key for that device (derived from its identity), for the audit's REST calls
#   dev     the device name (for the instructions in error messages)
#   pair_addr, pair_code   `android <device> pair <ip:port> <code>`: pair this host's key with the phone first
#                      (Wireless debugging > Pair device with pairing code; the code arrives here, never in an argument list)
#   act=channel        one-time setup of the management channel (adb): installs Termux, Termux:Boot and Shizuku from the
#                      catalog, grants what they need, pushes the sshd setup into Termux, starts Shizuku, verifies ssh
#   act=reconcile      install and update the catalog's apps silently (see android-reconcile.sh for its variables)
#   act=productivity   configure the notes and calendar apps instead (`stages`: syncthing orgzly davx5 fossify;
#                      zip_b64: the Syncthing import archive; dav_pass: the Baikal password; dry=1: print only;
#                      wait_s: how long each tap is awaited, default 600). Each app is its own stage: one failing or
#                      timing out never stops the others, a summary table closes the run and the exit status is non-zero
#                      unless every stage is ok.
# Secrets arrive on stdin or in these variables, never in an argument list.

# a stand-in phone for dry=1: every read is answered from canned data, every write is printed (stdin masked).
# stub=<name> picks a failure: noport (nothing open), unpaired (a port is open, adb connect fails), nolaunch (no launcher
# intent resolves; monkey still works), nolaunch-all (monkey fails too), badcode (wrong pairing code), nochannel (the
# sshd is not up, adb is), noshizuku (sshd is up, Shizuku is down, adb is not reachable), noshizuku-adb (Shizuku is
# down, adb can start it), alldown (nothing answers), failinstall (pm install fails), ratelimit (GitHub answers 403)
dry_stubs() {
  exec 9>&2 # the callers redirect stdout and stderr; the printed commands must still show
  HOME=$(mktemp -d)
  export HOME
  chan_key=$HOME/ssh_key
  : >"$chan_key"
  tailscale() { echo 100.64.0.99; }
  nmap() { case "${stub:-}" in noport | alldown | noshizuku | nochannel-noadb) ;; *) echo "Host: 100.64.0.99 ()	Ports: 37000/open/tcp//unknown///" ;; esac; }
  [ "${stub:-}" = never-setup ] || { mkdir -p "$HOME/.android"; printf 'user=u0_a345\n' >"$HOME/.android/channel-${1:-device}.conf"; }
  sleep() { :; }
  fake_pkgs() { printf '%s\n' "com.termux 1002 0.118.3" "org.jellyfin.mobile 1 2.6.0" "com.example.old 5 1.0.0"; }
  # one phone shell command (the text the real shell would get)
  fake_shell() {
    local c=$1
    case "$c" in
      "getprop ro.build.version.release") echo 17 ;;
      "getprop ro.product.cpu.abilist") echo arm64-v8a,armeabi-v7a,armeabi ;;
      "id -u")
        case "${stub:-}" in
          noshizuku | alldown) return 1 ;;
          noshizuku-adb) [ -e "$HOME/.shizuku-started" ] && echo 2000 || return 1 ;;
          *) echo 2000 ;;
        esac
        ;;
      "settings get global settings_enable_monitor_phantom_procs") echo false ;;
      "/system/bin/device_config get activity_manager max_phantom_processes") echo 2147483647 ;;
      "dumpsys deviceidle whitelist") printf '%s\n' "system-excidle,com.android.shell,2000" "user,com.termux,10345" "user,com.termux.boot,10346" "user,moe.shizuku.privileged.api,10347" ;;
      "settings get"*) echo null ;;
      "pm list packages -3 -i"*) printf '%s\n' "package:com.termux  installer=dev.imranr.obtainium" "package:org.jellyfin.mobile  installer=dev.imranr.obtainium" ;;
      "for p in"*) fake_pkgs ;;
      "pm install"* | "cp "*" && pm install"*)
        printf '+ shell %s\n' "$c" >&9
        if [ "${stub:-}" = failinstall ]; then echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]"; else echo Success; fi ;;
      "dumpsys window"*) echo "  mCurrentFocus=Window{abc u0 com.termux/com.termux.app.TermuxActivity}" ;;
      "ps -A"*) echo "u0_a345 123 1 bash" ;;
      "test -f /sdcard/Android/data/moe.shizuku"*) return 0 ;;
      "test -f"*"/done") return 0 ;;
      "cat /sdcard/Download/termux-channel/user") echo u0_a345 ;;
      "cat /sdcard/Download/termux-channel/hostkey") echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDRYSTUBHOSTKEY root@localhost" ;;
      "pm list packages"* | "dumpsys"* | "appops get"* | "content query"*) return 0 ;;
      "pm path"* | "test"*) return 1 ;;
      "monkey"*) [ "${stub:-}" != nolaunch-all ] || return 1 ;;
      "am start"*) if [[ "${stub:-}" == nolaunch* ]]; then echo "Error: Activity not started, unable to resolve Intent { $c }"; return 255; fi ;;
      "cmd package resolve-activity"*) [[ "${stub:-}" == nolaunch* ]] || echo "com.example/.Main" ;;
      *) printf '+ shell %s\n' "$c" >&9 ;;
    esac
  }
  ssh() {
    local args=("$@") last="${*: -1}" b c
    case "${stub:-}" in nochannel | alldown | nochannel-noadb) return 255 ;; esac
    case "$last" in
      true) return 0 ;;
      *"base64 -d"*)
        b=$(sed -n 's/.*printf %s \([A-Za-z0-9+\/=]*\) | base64 -d.*/\1/p' <<<"$last")
        c=$(printf '%s' "$b" | base64 -d)
        fake_shell "$c"
        ;;
      cat\ \>*|mkdir*) printf '+ ssh push %s <<< %s bytes\n' "$last" "$(wc -c | tr -d ' ')" >&9 ;;
      *) printf '+ ssh %s\n' "$last" >&9 ;;
    esac
  }
  ssh-keygen() { case "$1" in -y) echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISTUBPUBKEY android-channel" ;; *) return 0 ;; esac; }
  unzip() { printf 'stub-%s' "${*: -1}"; }
  curl() {
    local args=("$@") i out="" hdr="" url="${*: -1}" wcode="" body=""
    for ((i = 0; i < ${#args[@]}; i++)); do
      case "${args[$i]}" in
        -o) out=${args[$((i + 1))]} ;;
        -D) hdr=${args[$((i + 1))]} ;;
        -w) wcode=${args[$((i + 1))]} ;;
      esac
    done
    case "$url" in
      https://api.github.com/*) [ "${stub:-}" != ratelimit ] || { [ -z "$hdr" ] || : >"$hdr"; [ -z "$wcode" ] || printf 403; return 0; }; body=$(dry_github "$url") ;;
      https://f-droid.org/api/v1/packages/*) body=$(dry_fdroid "${url##*/}") ;;
      https://apt.izzysoft.de/*/api/v1/packages/*) body='{"error": "package not found"}' ;;
      https://ntfy.*) printf '+ ntfy %s\n' "$url" >&9; return 0 ;;
      https://*)
        if [ -n "$out" ]; then printf 'APK' >"$out"; fi
        return 0
        ;;
      *) return 7 ;;
    esac
    [ -z "$hdr" ] || printf 'HTTP/2 200\r\netag: "stub"\r\n' >"$hdr"
    if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
    [ -z "$wcode" ] || printf 200
  }
  adb() {
    local args=("$@") n
    [ "${args[0]:-}" = -s ] && args=("${args[@]:2}")
    case "${args[*]}" in
      devices) printf 'List of devices attached\n'; [ -n "${stub:-}" ] || printf '100.64.0.99:37000\tdevice\n'; return ;;
      pair*) cat >/dev/null; [ "${stub:-}" = badcode ] && echo "Failed: Wrong password or connection was dropped" || echo "Successfully paired to ${args[1]} [guid=adb-stub]"; return ;;
      connect*) if [ "${stub:-}" = unpaired ]; then echo "failed to connect to '${args[1]}'"; else echo "connected to ${args[1]}"; fi; return ;;
      "forward tcp:0 tcp:8384") echo 38384; return ;;
      "push "* | "install "*) printf '+ adb %s\n' "${args[*]}" >&9; return ;;
      "shell sh "*) printf '+ adb %s\n' "${args[*]}" >&9; : >"$HOME/.shizuku-started"; return ;;
      "shell input"*) printf '+ adb %s\n' "${args[*]}" >&9; return ;;
      shell\ *)
        # a secret travels on stdin: count it, never print it
        if [ -p /dev/stdin ]; then
          printf '+ adb %s <<< stdin: %s bytes, masked\n' "${args[*]}" "$(wc -c | tr -d ' ')" >&9
          return
        fi
        fake_shell "${args[*]:1}"
        return
        ;;
    esac
    n=""
    [ ! -p /dev/stdin ] || n=" <<< stdin: $(wc -c | tr -d ' ') bytes, masked"
    printf '+ adb %s%s\n' "${args[*]}" "$n" >&9
  }
}

# canned GitHub release lists and F-Droid answers for the dry run and its tests (tools/android-channel-test)
dry_github() {
  case "$1" in
    */RikkaApps/Shizuku/*) echo '[{"tag_name":"v13.6.0","draft":false,"prerelease":false,"assets":[{"name":"shizuku-v13.6.0.r1086-release.apk","browser_download_url":"https://github.com/RikkaApps/Shizuku/releases/download/v13.6.0/shizuku.apk"}]}]' ;;
    */jellyfin/jellyfin-android/*) echo '[{"tag_name":"v2.7.0","draft":false,"prerelease":false,"assets":[{"name":"jellyfin-android-v2.7.0-libre-release.apk","browser_download_url":"https://example.invalid/libre.apk"},{"name":"jellyfin-android-v2.7.0-gplay-release.apk","browser_download_url":"https://example.invalid/gplay.apk"}]},{"tag_name":"v2.6.0","draft":false,"prerelease":false,"assets":[]}]' ;;
    */nightly/app/*) echo '[{"tag_name":"nightly","draft":false,"prerelease":true,"assets":[{"name":"app-arm64-v8a.apk","browser_download_url":"https://example.invalid/n-arm64.apk"},{"name":"app-x86_64.apk","browser_download_url":"https://example.invalid/n-x86.apk"}]},{"tag_name":"v1.0","draft":false,"prerelease":false,"assets":[{"name":"app-universal.apk","browser_download_url":"https://example.invalid/stable.apk"}]}]' ;;
    *) echo '[]' ;;
  esac
}
dry_fdroid() {
  case "$1" in
    com.termux) echo '{"packageName":"com.termux","suggestedVersionCode":1002,"packages":[{"versionName":"0.119.0-beta.3","versionCode":1022},{"versionName":"0.118.3","versionCode":1002}]}' ;;
    com.termux.boot) echo '{"packageName":"com.termux.boot","suggestedVersionCode":1000,"packages":[{"versionName":"0.8.1","versionCode":1000}]}' ;;
    com.example.fd) echo '{"packageName":"com.example.fd","suggestedVersionCode":20,"packages":[{"versionName":"2.0","versionCode":20}]}' ;;
    *) echo '{"error":"NOT_FOUND"}' ;;
  esac
}

serial=""
transport=""
ssh_dest=""
ssh_opts=()
rish=/data/data/com.termux/files/usr/bin/rish
zip_pushed=""
# the Syncthing archive holds a private key: remove it however the run ends
cleanup() {
  [ -z "$zip_pushed" ] || a shell rm -f "$zip_pushed" >/dev/null 2>&1 || true
  [ -z "${work:-}" ] || rm -rf "$work"
}

# a shell <command...>: one command in the phone's shell, over whichever transport is up. adb: `adb shell` (text joined
# with spaces, interpreted once by the phone). ssh: Shizuku's rish, so the command runs as `shell`; the text travels
# base64-encoded, so no quoting layer of Termux's bash can touch it. Other adb verbs (forward, push) are adb only.
a() {
  if [ "$transport" = ssh ]; then
    [ "${1:-}" = shell ] || { echo "a $*: adb only" >&2; return 1; }
    shift
    local b
    b=$(printf '%s' "$*" | base64 | tr -d '\n')
    # a pending Shizuku permission dialog blocks rish until it is answered: do not wait for ever
    if [ -z "${dry:-}" ] && command -v timeout >/dev/null; then set -- timeout "${rish_timeout:-300}"; else set --; fi
    "$@" ssh "${ssh_opts[@]}" "$ssh_dest" "$rish -c \"\$(printf %s $b | base64 -d)\"" </dev/null
  else
    adb -s "$serial" "$@" </dev/null
  fi
}
# push_file <local> <remote>: onto shared storage, where the phone's shell can read it
push_file() {
  if [ "$transport" = ssh ]; then
    # shellcheck disable=SC2029 # the directory is for the phone's shell
    ssh "${ssh_opts[@]}" "$ssh_dest" "mkdir -p '$(dirname "$2")' && cat > '$2'" <"$1"
  else
    adb -s "$serial" push "$1" "$2" </dev/null >/dev/null
  fi
}
# priv_ok: the shell runs as shell (2000) or root: Shizuku (or adb) is up
priv_ok() {
  local u
  u=$(a shell id -u 2>/dev/null | tr -d '\r') || return 1
  [ "$u" = 2000 ] || [ "$u" = 0 ]
}

# ssh_connect <ip>: the management channel answers with the pinned host key and this host's key
ssh_connect() {
  local ip=$1 user port=${chan_port:-8022}
  chan_key=${chan_key:-$HOME/.android/ssh_key}
  user=$(sed -n 's/^user=//p' "$HOME/.android/channel-${host:-x}.conf" 2>/dev/null | head -1 || true)
  [ -n "$user" ] && [ -r "$chan_key" ] || return 1
  ssh_dest=$user@$ip
  ssh_opts=(-i "$chan_key" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=8 -o ServerAliveInterval=15
    -o "UserKnownHostsFile=${chan_known:-$HOME/.android/known_hosts}" -o StrictHostKeyChecking=yes -o LogLevel=ERROR)
  ssh "${ssh_opts[@]}" "$ssh_dest" true </dev/null 2>/dev/null
}

# adb_connect <ip>: sets `serial`. 0 connected, 3 no port / unpaired, 4 pairing failed.
adb_connect() {
  local ip=$1 ports="" port
  serial=$(adb devices </dev/null | awk -v p="$ip:" 'index($1, p) == 1 && $2 == "device" {print $1; exit}')
  if [ -z "$serial" ]; then
    # the TLS port is random per boot (Android 11+)
    ports=$(nmap -Pn -T4 --min-rate 2000 -p 5555,30000-49999 --open -oG - "$ip" </dev/null | grep -o '[0-9]*/open' | cut -d/ -f1 || true)
    for port in $ports; do
      if adb connect "$ip:$port" </dev/null | grep -Eq '^(connected|already)'; then
        serial=$ip:$port
        break
      fi
    done
  fi
  if [ -z "$serial" ] && [ -n "$ports" ]; then
    # a port is open and adb still cannot connect: Android 11+ drops a TLS client whose key is not paired, with no prompt on the phone
    echo "error $host ($ip): port $(tr '\n' ' ' <<<"$ports")open, but adb connect failed: this host's adb key is not paired with the phone." >&2
    echo "  On the phone: Developer options > Wireless debugging > Pair device with pairing code (note the pairing IP:port and the 6-digit code, the pairing port is not the connect port), then:" >&2
    echo "  android ${dev:-<device>} pair <ip:pairing-port> <code>" >&2
    return 3
  fi
  if [ -z "$serial" ]; then
    echo "error $host ($ip): no open adb port; turn on Developer options > Wireless debugging (it turns itself off when Wi-Fi changes)" >&2
    return 3
  fi
}

# shizuku_start_adb: Shizuku died with a reboot; its own start script runs under adb (any adb, wireless included)
shizuku_start_adb() {
  local sh=/sdcard/Android/data/moe.shizuku.privileged.api/start.sh i
  a shell "test -f $sh" || {
    # the manager writes the script the first time it opens
    launch moe.shizuku.privileged.api || return 1
    for ((i = 0; i < 15; i++)); do a shell "test -f $sh" && break; sleep 2; done
    a shell "test -f $sh" || return 1
  }
  a shell "sh $sh" >/dev/null 2>&1 || true
}

main() {
  set -euo pipefail
  local host=$1 ip s out via=${tp:-auto} rc=0
  priv=up

  trap cleanup EXIT
  [ -z "${dry:-}" ] || dry_stubs "$host"
  ip=$(tailscale ip -4 "$host")
  if [ -n "${pair_addr:-}" ]; then
    # Android 11+ authenticates the TLS connection with a paired key: an unpaired key just gets "failed to connect".
    # The pairing port differs from the connect port, and the code is good for one pairing.
    out=$(printf '%s\n' "${pair_code:-}" | adb pair "$pair_addr" 2>&1) || true
    if ! grep -q '^Successfully paired' <<<"$out"; then
      echo "error $host: pairing with $pair_addr failed: ${out:-no output}" >&2
      echo "  Pairing needs the dialog Developer options > Wireless debugging > Pair device with pairing code to stay open; the code and port change each time it opens." >&2
      return 4
    fi
    echo "paired $pair_addr"
  fi
  case "${act:-status}" in channel | productivity) via=adb ;; esac
  # the channel first
  if [ "$via" != adb ] && ssh_connect "$ip"; then
    transport=ssh
    serial="ssh:$ssh_dest:${chan_port:-8022}"
    if ! priv_ok; then
      # sshd answers but Shizuku is down (the phone rebooted): adb can start it when the phone is on home Wi-Fi
      local ssh_serial=$serial started="" adb_serial=""
      priv=down
      transport=adb
      if adb_connect "$ip" 2>/dev/null; then
        adb_serial=$serial
        if shizuku_start_adb; then started=1; fi
      fi
      transport=ssh
      serial=$ssh_serial
      if [ -n "$started" ]; then
        for _ in 1 2 3 4 5 6; do
          if priv_ok; then priv=up; break; fi
          sleep 3
        done
      fi
      # Shizuku did not come up (or never will on this release) but wireless debugging answers: adb is the same shell
      if [ "$priv" != up ] && [ -n "$adb_serial" ]; then
        transport=adb
        serial=$adb_serial
        priv=up
        echo "shizuku down, adb (wireless debugging) answers: using adb for this run"
      fi
      if [ "$transport" = ssh ] && [ "$priv" = up ]; then echo "shizuku started over adb"; elif [ "$priv" != up ]; then echo "shizuku down"; fi
    fi
  elif [ "$via" = ssh ]; then
    echo "error $host ($ip): the management channel does not answer (sshd in Termux down, or never set up: android ${dev:-<device>} channel)" >&2
    return 3
  else
    transport=adb
    adb_connect "$ip" || return $?
  fi
  echo "transport $transport"
  echo "serial $serial"
  s=$serial
  if [ "$priv" = down ]; then
    # nothing privileged can run: reconcile reports its apps as pending, the audit says why it is empty
    if [ "${act:-status}" = reconcile ]; then
      reconcile || rc=$?
      return "$rc"
    fi
    echo "error $host: the channel is up but Shizuku is not running and adb is not reachable (the phone rebooted away from home Wi-Fi?): nothing privileged can run until it is on home Wi-Fi again, or until Shizuku is started on the phone" >&2
    return 6
  fi
  [ "$transport" != ssh ] || echo "shizuku up"
  echo "release $(a shell getprop ro.build.version.release)"
  case "${act:-status}" in
    productivity)
      productivity "$serial"
      return
      ;;
    channel)
      channel "$ip"
      return
      ;;
    reconcile)
      reconcile || rc=$?
      return "$rc"
      ;;
  esac
  echo "vpn_app $(a shell settings get secure always_on_vpn_app)"
  echo "vpn_lockdown $(a shell settings get secure always_on_vpn_lockdown)"
  a shell pm list packages -3 -i | sed -n 's/^package:\([^ ]*\) *installer=\([^ ]*\).*$/pkg \1 \2/p'
  if [ -n "${link:-}" ] && [ "$transport" = adb ]; then
    # via stdin: the link can exceed adb's command-line limit
    # shellcheck disable=SC2016 # $(cat) is for the phone's shell
    printf '%s' "$link" | adb -s "$serial" shell 'am start -a android.intent.action.VIEW -d "$(cat)"' >/dev/null
    echo "opened import"
  fi
  if [ -n "${spec:-}" ]; then
    audit "$serial"
  fi
}

# ---- the notes and calendar stack ------------------------------------------------------------------

# sp <jq filter>: a field of the productivity spec
sp() { jq -r "$1" <<<"$spec"; }

have_pkg() { [ -n "$(a shell pm path "$1" 2>/dev/null || true)" ]; }

# the SAF-free file API of Syncthing-Fork, behind `adb forward`: needs the derived API key
st_open() {
  if [ "$transport" = ssh ]; then
    st_ctl=$HOME/.android/ctl-$$
    st_port=$((20000 + RANDOM % 20000))
    ssh -f -N -M -S "$st_ctl" "${ssh_opts[@]}" -o ExitOnForwardFailure=yes -L "127.0.0.1:$st_port:127.0.0.1:8384" "$ssh_dest" </dev/null 2>/dev/null || st_port=""
  else
    st_port=$(adb -s "$1" forward tcp:0 tcp:8384 </dev/null 2>/dev/null) || st_port=""
  fi
}
st_close() {
  [ -n "${st_port:-}" ] || return 0
  if [ "$transport" = ssh ]; then
    ssh -S "${st_ctl:-/nonexistent}" -O exit "$ssh_dest" </dev/null >/dev/null 2>&1 || true
  else
    adb -s "$1" forward --remove "tcp:$st_port" </dev/null >/dev/null 2>&1 || true
  fi
}
slashes=//
# st_get <path>: GET on the phone's Syncthing REST API; the key goes through a config file descriptor, not argv
st_get() {
  local proto
  [ -n "${st_port:-}" ] && [ -n "${st_key:-}" ] || return 1
  for proto in https http; do
    curl -sfk --max-time 8 -K <(printf 'header = "X-API-Key: %s"\n' "$st_key") "${proto}:${slashes}127.0.0.1:${st_port}$1" 2>/dev/null && return 0
  done
  return 1
}

# davx5 account names (Android account type bitfire.at.davdroid, core/src/main/res/values/strings.xml)
dav_accounts() {
  local d
  d=$(a shell dumpsys account 2>/dev/null || true)
  sed -n 's/.*Account {name=\([^,]*\), type=bitfire\.at\.davdroid}.*/\1/p' <<<"$d" | sort -u
}
# the calendars DAVx5 hands to the Calendar Provider (only the ticked ones); empty when the provider is not readable
dav_calendars() {
  local rows
  rows=$(a shell content query --uri content://com.android.calendar/calendars --projection calendar_displayName:account_type --where "account_type=\'bitfire.at.davdroid\'" 2>/dev/null || true)
  sed -n 's/^Row: [0-9]* calendar_displayName=\(.*\), account_type=bitfire\.at\.davdroid$/\1/p' <<<"$rows"
}

# the address books DAVx5 hands to the Contacts Provider: it makes one sync account per ticked address book, type
# at.bitfire.davdroid.address_book (core strings.xml), named "<book> (<account>)" plus a collection id suffix
dav_addressbooks() {
  local d
  d=$(a shell dumpsys account 2>/dev/null || true)
  sed -n 's/.*Account {name=\(.*\), type=at\.bitfire\.davdroid\.address_book}.*/\1/p' <<<"$d" | sort -u
}

audit() {
  local s=$1 id hub org ver st dir accts cals books pkg apps
  apps=$(sp '.apps | to_entries | map("\(.key)=\(.value)") | join(" ")')
  for pkg in $apps; do
    ver=$(a shell dumpsys package "${pkg#*=}" 2>/dev/null | sed -n 's/^ *versionName=//p' | head -1 || true)
    if [ -n "$ver" ]; then echo "prod ok ${pkg%%=*}: installed ($ver)"; else echo "prod DRIFT ${pkg%%=*}: ${pkg#*=} is not installed"; fi
  done

  # Syncthing-Fork: its identity, the hub link and the folder, over the REST API
  id=$(sp .syncthing.id)
  hub=$(sp .syncthing.hub.id)
  org=$(sp .syncthing.folder.id)
  dir=$(sp .orgDir)
  if [ "$id" = null ]; then
    echo "prod DRIFT syncthing: no device ID recorded for $(sp .syncthing.device) (syncthing-identity, docs/manual-steps.md step 11)"
  elif [ -z "${st_key:-}" ]; then
    echo "prod DRIFT syncthing: no identity secret to derive the API key (secrets/sops/syncthing-$(sp .syncthing.device).yaml)"
  else
    st_open "$s"
    st=$(st_get /rest/system/status | jq -r .myID 2>/dev/null || true)
    if [ -z "$st" ]; then
      echo "prod DRIFT syncthing: REST API not answering (service stopped, or the config was never imported: android $(sp .syncthing.device) productivity)"
    elif [ "$st" != "$id" ]; then
      echo "prod DRIFT syncthing: running as another device (${st%%-*}...), expected ${id%%-*}...: import the generated config (android $(sp .syncthing.device) productivity)"
    else
      echo "prod ok syncthing: service running as ${id%%-*}..."
      if [ "$(st_get /rest/system/connections | jq -r --arg h "$hub" '.connections[$h].connected' 2>/dev/null || true)" = true ]; then
        echo "prod ok syncthing: hub connected"
      else
        echo "prod DRIFT syncthing: hub not connected (the hub accepts the ID only after the cluster has the table: merge, then sync)"
      fi
      echo "prod ok syncthing: folder $org $(st_get "/rest/db/status?folder=$org" | jq -r '"\(.state), \(.needTotalItems) items to sync"' 2>/dev/null || echo "state unknown")"
    fi
    st_close "$s"
  fi
  if a shell test -d "$dir/.stfolder" 2>/dev/null; then echo "prod ok syncthing: $dir/.stfolder exists"; else echo "prod DRIFT syncthing: $dir/.stfolder is missing (android $(sp .syncthing.device) productivity creates it)"; fi

  # Orgzly: the repository itself lives in its private database, which adb cannot read
  if [ "$(a shell appops get "$(sp .apps.orgzly)" MANAGE_EXTERNAL_STORAGE 2>/dev/null || true)" = "MANAGE_EXTERNAL_STORAGE: allow" ]; then
    echo "prod ok orgzly: all-files access allowed (the repository is not readable over adb)"
  else
    echo "prod DRIFT orgzly: all-files access not allowed (android $(sp .syncthing.device) productivity)"
  fi

  # DAVx5 account and the ticked calendar
  accts=$(dav_accounts)
  if [ -z "$accts" ]; then
    echo "prod DRIFT davx5: no Baikal account (android $(sp .syncthing.device) productivity)"
  else
    echo "prod ok davx5: account $(tr '\n' ' ' <<<"$accts")"
    books=$(dav_addressbooks)
    if grep -q "^$(sp .caldav.addressbook) (" <<<"$books"; then
      echo "prod ok davx5: address book $(sp .caldav.addressbook) is synced"
    elif [ -z "$books" ]; then
      echo "prod DRIFT davx5: no address book synced (tick $(sp .caldav.addressbook) under CardDAV in DAVx5), or the accounts are not readable over adb"
    else
      echo "prod DRIFT davx5: address book $(sp .caldav.addressbook) is not ticked (has: $(tr '\n' ' ' <<<"$books"))"
    fi
    cals=$(dav_calendars)
    if grep -qx "$(sp .caldav.calendar)" <<<"$cals"; then
      echo "prod ok davx5: calendar $(sp .caldav.calendar) is synced"
    elif [ -z "$cals" ]; then
      echo "prod DRIFT davx5: no calendar synced (tick $(sp .caldav.calendar) in DAVx5), or the Calendar Provider is not readable over adb"
    else
      echo "prod DRIFT davx5: calendar $(sp .caldav.calendar) is not ticked (has: $(tr '\n' ' ' <<<"$cals"))"
    fi
  fi

  # Fossify Calendar: permission only; its CalDAV toggle is a private preference
  if a shell dumpsys package "$(sp .apps.calendar)" 2>/dev/null | grep -q 'android.permission.READ_CALENDAR: granted=true'; then
    echo "prod ok calendar: calendar permission granted (the CalDAV toggle is not readable over adb)"
  else
    echo "prod DRIFT calendar: calendar permission not granted (android $(sp .syncthing.device) productivity)"
  fi
}

# grant <package> <permission>...: runtime permissions the app would otherwise ask for (a failure is a permission
# this Android version does not have, or one the app does not declare)
grant() {
  local pkg=$1 p
  shift
  for p in "$@"; do a shell pm grant "$pkg" "android.permission.$p" >/dev/null 2>&1 || true; done
}
# keep the app out of battery optimisation (an adb-settable whitelist); allfiles also grants all-files access
loosen() {
  a shell cmd deviceidle whitelist "+$1" >/dev/null 2>&1 || true
}
allfiles() { a shell appops set "$1" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true; }
# launch <package>: open the app. `am start` can exit 0 with "Error: Activity not started" on its output, so the
# output is checked; when the MAIN/LAUNCHER intent does not resolve (a replaced build, another launcher activity) ask
# the package manager for the launcher activity, then fall back to monkey. Fails only when all three do.
launch() {
  local pkg=$1 out act
  out=$(a shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p "$pkg" 2>&1) && ! grep -q '^Error' <<<"$out" && return 0
  act=$(a shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$pkg" 2>/dev/null | tail -1 | tr -d '\r' || true)
  if [[ "$act" == */* ]]; then
    out=$(a shell am start -n "$act" 2>&1) && ! grep -q '^Error' <<<"$out" && return 0
  fi
  a shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 && return 0
  return 1
}
# minutes <seconds>: "10 minutes"
minutes() { local m=$(($1 / 60)); if [ "$m" -ge 1 ]; then echo "$m minute$([ "$m" -eq 1 ] || echo s)"; else echo "$1 seconds"; fi; }
# poll <seconds> <command...>: until it succeeds; prints how long is left every minute, so a buffered terminal shows progress
poll() {
  local n=$1 i
  shift
  [ -z "${dry:-}" ] || return 0
  for ((i = 0; i < n; i += 5)); do
    "$@" && return 0
    [ "$i" -eq 0 ] || [ $((i % 60)) -ne 0 ] || say "   ... still waiting, $(minutes $((n - i))) left"
    sleep 5
  done
  return 1
}
want_stage() { [ -z "${stages:-}" ] || [[ " $stages " == *" $1 "* ]]; }
say() { printf '%s\n' "$*"; }

# run_stage <name> <function> [args]: one app per stage, in a subshell with errexit, so a failing command ends only that
# stage (errexit is ignored inside a condition, hence the background job and wait). A stage returns 0 (ok), 10 (the tap
# was not seen in time) or 11 (the app is not installed); `note` leaves a line for the summary.
results=()
run_stage() {
  local name=$1 rc=0 status
  shift
  : >"$notes"
  ( set -e; trap cleanup EXIT; "$@" ) </dev/null &
  wait $! || rc=$?
  case $rc in
    0) status=ok ;;
    10) status=TIMEOUT ;;
    11) status=MISSING ;;
    *) status="FAILED($rc)" ;;
  esac
  results+=("$(printf '%-10s %-10s %s' "$name" "$status" "$(tail -1 "$notes")")")
  [ "$rc" -eq 0 ] || failed=1
  return 0
}
note() { printf '%s\n' "$*" >>"$notes"; }
# need_pkg <package>: a stage's first step. A missing package is reported and ends only that stage.
need_pkg() {
  have_pkg "$1" || [ -n "${dry:-}" ] || { say "   $1 is not installed: run 'android $(sp .syncthing.device) apply' first"; note "$1 is not installed"; return 11; }
}

productivity() {
  local s=$1
  local dev org dir failed=0 notes
  notes=$(mktemp)
  dev=$(sp .syncthing.device)
  org=$(sp .syncthing.folder.id)
  dir=$(sp .orgDir)
  say "$dev: unlock the phone and keep the screen on; each app opens in turn. Each tap is awaited for $(minutes "${wait_s:-600}") (--wait)."
  want_stage syncthing && run_stage syncthing stage_syncthing "$s" "$dir"
  want_stage orgzly && run_stage orgzly stage_orgzly "$dir"
  want_stage davx5 && run_stage davx5 stage_davx5 "$s"
  want_stage fossify && run_stage fossify stage_fossify
  rm -f "$notes"
  say "== summary"
  printf '%s\n' "${results[@]}"
  if [ "$failed" -eq 0 ]; then
    say "done. Check the result with: android $dev"
  else
    say "not every stage succeeded: fix the ones above and rerun (stages are idempotent; name one to run only it: android $dev productivity <stage>)" >&2
  fi
  return "$failed"
}

stage_syncthing() {
  local s=$1 dir=$2 pkg id st zip=/sdcard/backups/syncthing/config.zip rc=0 launched=1
  pkg=$(sp .apps.syncthing)
  id=$(sp .syncthing.id)
  say "== Syncthing-Fork ($pkg)"
  need_pkg "$pkg" || return
  loosen "$pkg"
  allfiles "$pkg"
  grant "$pkg" POST_NOTIFICATIONS ACCESS_LOCAL_NETWORK
  # Syncthing refuses a folder without its marker
  a shell mkdir -p "$dir/.stfolder"
  st_open "$s"
  st=$(st_get /rest/system/status | jq -r .myID 2>/dev/null || true)
  if [ "$st" = "$id" ]; then
    say "   already running as the declared device ($id): nothing to import"
    note "already running as the declared device"
    st_close "$s"
    return
  fi
  st_close "$s"
  # the archive holds the device's private key: it lives on shared storage only while the import runs
  a shell mkdir -p "$(dirname "$zip")"
  if a shell test -e "$zip" 2>/dev/null; then
    a shell mv "$zip" "$zip.prev"
    say "   an existing $zip was moved to $zip.prev"
  fi
  zip_pushed=$zip
  printf '%s' "${zip_b64:-}" | base64 -d | adb -s "$s" shell "cat > $zip"
  launch "$pkg" || { say "   could not open $pkg: open Syncthing-Fork by hand"; launched=0; }
  say "   TAP (once, on the phone): in Syncthing-Fork open the menu, Settings, Import and Export, Import Configuration, OK."
  say "   On a fresh install, first click through the welcome page and tap Finish after key generation."
  if [ -n "${dry:-}" ]; then
    say "   (dry run: would now wait for the phone to run as ${id%%-*}..., then remove $zip)"
    note "dry run"
    return
  fi
  say "   waiting up to $(minutes "${wait_s:-600}") for the phone to run as ${id%%-*}..."
  st_open "$s"
  if poll "${wait_s:-600}" st_is_declared; then
    say "   imported: running as the declared device"
    note "imported, running as the declared device"
  else
    say "   not seen within $(minutes "${wait_s:-600}"); the archive is removed, rerun to try again (--wait for longer)" >&2
    note "the import tap was not seen within $(minutes "${wait_s:-600}")"
    rc=10
  fi
  st_close "$s"
  cleanup
  zip_pushed=""
  [ "${launched:-1}" -eq 1 ] || [ "$rc" -ne 0 ] || { note "could not open the app, imported anyway"; }
  return "$rc"
}
st_is_declared() { [ "$(st_get /rest/system/status | jq -r .myID 2>/dev/null || true)" = "$(sp .syncthing.id)" ]; }

stage_orgzly() {
  local dir=$1 pkg rc=0
  pkg=$(sp .apps.orgzly)
  say "== Orgzly Revived ($pkg)"
  need_pkg "$pkg" || return
  loosen "$pkg"
  allfiles "$pkg"
  grant "$pkg" POST_NOTIFICATIONS WRITE_EXTERNAL_STORAGE
  a shell appops set "$pkg" SCHEDULE_EXACT_ALARM allow >/dev/null 2>&1 || true
  if ! launch "$pkg"; then
    say "   could not open $pkg (no launcher activity resolved; monkey failed too): open Orgzly by hand and do the tap below"
    note "could not open $pkg; permissions granted, the repository tap is still to do"
    rc=1
  fi
  say "   TAP (once, on the phone): menu, Settings, Repositories, New Repository, Directory, type"
  say "       file:$dir"
  say "   in 'Directory URI', tick to save, then Sync. (Orgzly keeps repositories in a private database: no intent or file sets one.)"
  [ "$rc" -ne 0 ] || note "permissions granted; the repository tap is on the phone"
  return "$rc"
}

stage_davx5() {
  local s=$1 pkg url user host u accounts
  pkg=$(sp .apps.davx5)
  url=$(sp .caldav.url)
  user=$(sp .caldav.user)
  say "== DAVx5 ($pkg)"
  need_pkg "$pkg" || return
  loosen "$pkg"
  grant "$pkg" POST_NOTIFICATIONS READ_CALENDAR WRITE_CALENDAR READ_CONTACTS WRITE_CONTACTS
  accounts=$(dav_accounts)
  if [ -n "$accounts" ]; then
    say "   account exists ($(tr '\n' ' ' <<<"$accounts")); tick the $(sp .caldav.calendar) calendar (CalDAV) and the $(sp .caldav.addressbook) address book (CardDAV) in the account if the audit says they are not synced"
    note "account exists"
    return
  fi
  # davx5://host/path is https://host/path (LoginActivity.loginInfoFromIntent): it skips the login-type page
  u=${url#https://}
  [ "$u" != "$url" ] || { say "   caldav.url must be https: $url" >&2; note "caldav.url must be https"; return 1; }
  host=davx5://$u
  # the password goes in on stdin and reaches `am` as a shell variable on the phone, never in an argument list here
  printf '%s\n' "${dav_pass:-}" | adb -s "$s" shell "IFS= read -r pw; am start -n $pkg/.ui.setup.LoginActivity -a android.intent.action.VIEW -d '$host' --es username '$user' --es password \"\$pw\"" >/dev/null
  say "   TAP (on the phone): Login, then (after the server is found) the name page: Create account."
  say "   then in the account tick the '$(sp .caldav.calendar)' calendar under CalDAV and the '$(sp .caldav.addressbook)' address book under CardDAV (DAVx5 preselects none)."
  if [ -n "${dry:-}" ]; then
    say "   (dry run: would now wait for the account, then for the '$(sp .caldav.calendar)' calendar)"
    note "dry run"
    return
  fi
  say "   waiting up to $(minutes "${wait_s:-600}") for the account, then as long for the calendar..."
  if poll "${wait_s:-600}" dav_has_account; then
    say "   account created"
  else
    say "   no account within $(minutes "${wait_s:-600}")" >&2
    note "no account within $(minutes "${wait_s:-600}")"
    return 10
  fi
  if poll "${wait_s:-600}" dav_has_calendar; then
    say "   calendar $(sp .caldav.calendar) is synced"
    if dav_addressbooks | grep -q "^$(sp .caldav.addressbook) ("; then
      note "account created, calendar and address book synced"
    else
      say "   address book $(sp .caldav.addressbook) not ticked yet (CardDAV tab; the audit checks it)" >&2
      note "account created, calendar synced, address book $(sp .caldav.addressbook) not seen"
    fi
  else
    say "   calendar $(sp .caldav.calendar) not ticked (or the Calendar Provider is not readable over adb)" >&2
    note "account created, calendar $(sp .caldav.calendar) not seen within $(minutes "${wait_s:-600}")"
    return 10
  fi
}
dav_has_account() { [ -n "$(dav_accounts)" ]; }
dav_has_calendar() { dav_calendars | grep -qx "$(sp .caldav.calendar)"; }

stage_fossify() {
  local pkg cal out rc=0
  pkg=$(sp .apps.calendar)
  cal=$(sp .caldav.calendar)
  say "== Fossify Calendar ($pkg)"
  need_pkg "$pkg" || return
  grant "$pkg" POST_NOTIFICATIONS READ_CALENDAR WRITE_CALENDAR
  # its settings screen first, else the launcher activity
  out=$(a shell am start -n "$pkg/.activities.SettingsActivity" 2>&1) && ! grep -q '^Error' <<<"$out" || launch "$pkg" || {
    say "   could not open $pkg: open Fossify Calendar by hand"
    rc=1
  }
  say "   TAP (once, on the phone, in Settings): turn on 'CalDAV sync', then 'Manage synced calendars' and tick '$cal'."
  say "   (needs DAVx5's account and ticked calendar first; the preference is private to the app)"
  if [ "$rc" -eq 0 ]; then note "permissions granted; the CalDAV tap is on the phone"; else note "could not open $pkg; the CalDAV tap is still to do"; fi
  return "$rc"
}

# ---- the management channel (one-time setup) --------------------------------------------------------

# shizuku_apk: the pinned Shizuku APK from the catalog's source, downloaded once (rish ships inside it)
# shellcheck disable=SC2154 # want comes from the caller
shizuku_apk() {
  local app res tag file url dir abi=arm64-v8a
  app=$(jq -c '.apps[] | select(.id == "moe.shizuku.privileged.api")' <<<"$want")
  [ -n "$app" ] || return 1
  res=$(resolve "$app" "$abi") || return 1
  tag=$(jq -r .tag <<<"$res")
  file=$(jq -r .file <<<"$res")
  url=$(jq -r .url <<<"$res")
  dir=$(rc_cache)/apk/moe.shizuku.privileged.api/$tag
  mkdir -p "$dir"
  [ -s "$dir/$file" ] || curl -fsSL --retry 3 -o "$dir/$file" "$url" || return 1
  printf '%s' "$dir/$file"
}

termux_shell_ready() {
  a shell "dumpsys window | grep -m1 mCurrentFocus" 2>/dev/null | grep -q 'com.termux/' \
    && a shell "ps -A | grep -E ' (bash|login)\$'" >/dev/null 2>&1
}
chan_setup_done() { a shell "test -f $1/done" >/dev/null 2>&1; }

# chan_setup_script <ip> <authorized_keys line>: what runs inside Termux, once and again on every `channel`
chan_setup_script() {
  local tpl wake='# (wakeLock = false: Doze may put the channel to sleep with the screen off)'
  [ "${chan_wakelock:-true}" != true ] || wake='termux-wake-lock'
  tpl=$(cat <<'TPL'
#!/data/data/com.termux/files/usr/bin/sh
# written by `android <device> channel` (docs/android-fleet.md); safe to run again
set -eu
D=/sdcard/Download/termux-channel
P=/data/data/com.termux/files/usr
rm -f "$D/done"
echo "== management channel: packages"
export DEBIAN_FRONTEND=noninteractive
pkg update -y >/dev/null 2>&1 || true
pkg install -y openssh termux-services
mkdir -p "$HOME/.ssh" "$HOME/.termux/boot" "$HOME/.rish"
chmod 700 "$HOME/.ssh"
printf '%s\n' '@AUTHKEY@' >"$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
[ -f "$P/etc/ssh/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$P/etc/ssh/ssh_host_ed25519_key"
cat >"$P/etc/ssh/sshd_config" <<'CFG'
# the management channel: the phone's tailnet address only, keys only (written by `android <device> channel`)
Port @PORT@
ListenAddress @IP@
HostKey /data/data/com.termux/files/usr/etc/ssh/ssh_host_ed25519_key
PidFile /data/data/com.termux/files/usr/var/run/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 20
AllowTcpForwarding local
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
PrintMotd no
LogLevel ERROR
ClientAliveInterval 60
ClientAliveCountMax 3
Subsystem sftp /data/data/com.termux/files/usr/libexec/sftp-server
CFG
echo "== management channel: rish (Shizuku's shell)"
rm -f "$HOME/.rish/rish" "$HOME/.rish/rish_shizuku.dex"
cp "$D/rish" "$HOME/.rish/rish"
cp "$D/rish_shizuku.dex" "$HOME/.rish/rish_shizuku.dex"
chmod 700 "$HOME/.rish/rish"
chmod 400 "$HOME/.rish/rish_shizuku.dex"
cat >"$P/bin/rish" <<'EOS'
#!/data/data/com.termux/files/usr/bin/sh
# Shizuku's shell for Termux: runs as `shell` while Shizuku is up
unset LD_PRELOAD LD_LIBRARY_PATH
export RISH_APPLICATION_ID=com.termux
exec /system/bin/sh "$HOME/.rish/rish" "$@"
EOS
chmod 755 "$P/bin/rish"
echo "== management channel: boot script (starts the runit supervisor; runit supervises sshd)"
rm -f "$HOME/.termux/boot/sshd"
cat >"$HOME/.termux/boot/channel" <<'EOB'
#!/data/data/com.termux/files/usr/bin/sh
# started by Termux:Boot after the first unlock following a boot: the wake lock, then termux-services' runit supervisor,
# which starts and restarts sshd (it retries until the tailnet address exists)
export PREFIX=/data/data/com.termux/files/usr
export PATH="$PREFIX/bin:$PATH"
@WAKE@
. "$PREFIX/etc/profile.d/start-services.sh"
EOB
chmod 700 "$HOME/.termux/boot/channel"
echo "== management channel: start (runit supervises sshd)"
# the previous bare-sshd loop of an earlier setup, and any sshd it left behind, would hold the port
if [ -f "$HOME/.termux/sshd-loop.pid" ]; then kill "$(cat "$HOME/.termux/sshd-loop.pid")" 2>/dev/null || true; rm -f "$HOME/.termux/sshd-loop.pid"; fi
if [ -f "$P/var/run/sshd.pid" ]; then kill "$(cat "$P/var/run/sshd.pid")" 2>/dev/null || true; fi
@WAKE@
export SVDIR="$P/var/service" LOGDIR="$P/var/log" PATH="$P/bin:$PATH"
. "$P/etc/profile.d/start-services.sh"
i=0
while [ ! -d "$SVDIR/sshd" ] && [ "$i" -lt 10 ]; do i=$((i + 1)); sleep 1; done
# openssh was installed before termux-services: reinstall it once so the service directory is linked into $SVDIR
[ -d "$SVDIR/sshd" ] || { pkg reinstall -y openssh; sleep 3; }
[ -d "$SVDIR/sshd" ] || { echo "error: no sshd service in $SVDIR" >&2; exit 1; }
# runsvdir scans $SVDIR every 5 seconds: wait for runsv to supervise sshd, or `sv up` says "unable to open supervise/ok"
i=0
while [ ! -e "$SVDIR/sshd/supervise/ok" ] && [ "$i" -lt 40 ]; do i=$((i + 1)); sleep 1; done
sv-enable sshd
sleep 3
sv status sshd | tee "$D/svstatus"
grep -q '^run: sshd' "$D/svstatus" || { echo "error: runit does not run sshd" >&2; exit 1; }
rm -f "$D/svstatus"
id -un >"$D/user"
cut -d' ' -f1,2 "$P/etc/ssh/ssh_host_ed25519_key.pub" >"$D/hostkey"
echo ok >"$D/done"
echo "== done: sshd listens on @IP@:@PORT@"
TPL
)
  tpl=${tpl//@AUTHKEY@/$2}
  tpl=${tpl//@PORT@/${chan_port:-8022}}
  tpl=${tpl//@IP@/$1}
  tpl=${tpl//@WAKE@/$wake}
  printf '%s\n' "$tpl"
}

# phantom_killer: Android 12+ kills an app's background child processes (the "phantom process killer": more than 32
# of them, or ones using a lot of CPU), and sshd forks one per session. Termux documents settings_enable_monitor_phantom_procs=false
# for Android 12L and later and device_config max_phantom_processes for Android 12 (also set here: harmless where the
# flag is unused); the device-wide `device_config set_sync_disabled_for_tests persistent` that guides add to stop Google
# overwriting the value is left out (it freezes every Google-pushed flag). Both values are read back and reported.
phantom_killer() {
  local mon max
  a shell "settings put global settings_enable_monitor_phantom_procs false; /system/bin/device_config put activity_manager max_phantom_processes 2147483647" >/dev/null 2>&1 || true
  mon=$(a shell settings get global settings_enable_monitor_phantom_procs 2>/dev/null | tr -d '\r' || true)
  max=$(a shell /system/bin/device_config get activity_manager max_phantom_processes 2>/dev/null | tr -d '\r' || true)
  say "   phantom process killer: settings_enable_monitor_phantom_procs=${mon:-unreadable} (want false), max_phantom_processes=${max:-unreadable} (want 2147483647)"
  [ "$mon" = false ] || say "   (not off: Termux's background processes may be killed; on Android 14+ also turn on Developer options > Disable child process restrictions)" >&2
}

# battery_report <pkg...>: which of them are on the Doze whitelist (cmd deviceidle whitelist, set by loosen)
battery_report() {
  local wl pkg
  wl=$(a shell dumpsys deviceidle whitelist 2>/dev/null | tr -d '\r' || true)
  for pkg in "$@"; do
    if grep -qE "(^|,)$pkg(,|\$)" <<<"$wl"; then say "   battery: $pkg is exempt from optimisation"
    else say "   battery: $pkg is NOT on the Doze whitelist (Settings > Apps > $pkg > Battery > Unrestricted)" >&2; fi
  done
}

# channel <phone tailnet ip>: sshd in Termux on the tailnet, started at boot by Termux:Boot, privileged through Shizuku.
# Runs over adb once; afterwards `android` reaches the phone over ssh first and falls back to adb.
channel() {
  local ip=$1 d=/sdcard/Download/termux-channel port=${chan_port:-8022} pub line user hk known rc=0 pkg apk
  chan_key=${chan_key:-$HOME/.android/ssh_key}
  known=${chan_known:-$HOME/.android/known_hosts}
  [ -r "$chan_key" ] || { echo "error: no channel key at $chan_key (pulumi android_ssh_key, docs/android-fleet.md)" >&2; return 1; }
  jq -e '[.apps[].id] | index("com.termux") != null' <<<"$want" >/dev/null \
    || { echo "error: $dev does not declare channel.enable (modules/android.nix)" >&2; return 1; }
  pub=$(ssh-keygen -y -f "$chan_key")
  line="restrict,port-forwarding${from_ip:+,from=\"$from_ip\"} $(cut -d' ' -f1,2 <<<"$pub") android-channel"
  say "== management channel for $dev (adb, once): unlock the phone and keep the screen on"

  say "-- Termux, Termux:Boot and Shizuku (silent over adb)"
  only="com.termux com.termux.boot moe.shizuku.privileged.api" reconcile || rc=$?
  [ "$rc" -eq 0 ] || { say "error: could not install the three apps (see above; a Termux from another source must be uninstalled first, the signatures differ)" >&2; return 1; }

  say "-- permissions and battery"
  for pkg in com.termux com.termux.boot moe.shizuku.privileged.api; do
    loosen "$pkg"
    a shell "appops set $pkg RUN_IN_BACKGROUND allow; appops set $pkg RUN_ANY_IN_BACKGROUND allow" >/dev/null 2>&1 || true
  done
  battery_report com.termux com.termux.boot moe.shizuku.privileged.api
  grant com.termux POST_NOTIFICATIONS READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE
  allfiles com.termux
  # lets Shizuku restart itself after a reboot on trusted Wi-Fi (Android 13+; its boot receiver checks this grant)
  a shell pm grant moe.shizuku.privileged.api android.permission.WRITE_SECURE_SETTINGS >/dev/null 2>&1 || say "   (Shizuku did not get WRITE_SECURE_SETTINGS: it will not restart itself after a reboot; bonobo's adb start still covers home Wi-Fi)"
  phantom_killer

  say "-- bundle onto the phone ($d)"
  work=$(mktemp -d)
  apk=$(shizuku_apk) || { say "error: could not fetch the Shizuku APK (rish ships inside it)" >&2; return 1; }
  unzip -p "$apk" assets/rish >"$work/rish"
  unzip -p "$apk" assets/rish_shizuku.dex >"$work/rish_shizuku.dex"
  [ -s "$work/rish" ] && [ -s "$work/rish_shizuku.dex" ] || { say "error: $apk has no rish assets" >&2; return 1; }
  chan_setup_script "$ip" "$line" >"$work/setup.sh"
  a shell "rm -rf $d; mkdir -p $d" >/dev/null
  push_file "$work/rish" "$d/rish"
  push_file "$work/rish_shizuku.dex" "$d/rish_shizuku.dex"
  push_file "$work/setup.sh" "$d/setup.sh"

  say "-- open Termux:Boot once (Android delivers no boot broadcast to an app that was never started)"
  a shell "am start -n com.termux.boot/.BootActivity" >/dev/null 2>&1 || launch com.termux.boot || true

  say "-- run the setup inside Termux (typed into its shell; the first start unpacks Termux and downloads openssh: a few minutes)"
  a shell "input keyevent KEYCODE_WAKEUP" >/dev/null 2>&1 || true
  launch com.termux || say "   could not open Termux: open it by hand"
  if ! poll "${wait_s:-900}" termux_shell_ready; then
    say "   Termux did not show a shell in time: open it and run: sh $d/setup.sh" >&2
  else
    sleep 5
    a shell "input text 'sh%s$d/setup.sh'" >/dev/null
    a shell "input keyevent 66" >/dev/null
  fi
  say "   waiting up to $(minutes "${wait_s:-900}") for the setup to finish (if the screen shows a prompt or an error, it needs you; the line to run is: sh $d/setup.sh)"
  if ! poll "${wait_s:-900}" chan_setup_done "$d"; then
    say "error: the setup did not finish; open Termux and run: sh $d/setup.sh, then run this again" >&2
    return 10
  fi
  user=$(a shell "cat $d/user" | tr -d '\r\n')
  hk=$(a shell "cat $d/hostkey" | tr -d '\r\n')
  [ -n "$user" ] && [ -n "$hk" ] || { say "error: the setup left no user or host key" >&2; return 1; }
  mkdir -p "$(dirname "$known")" "$HOME/.android"
  ssh-keygen -R "[$ip]:$port" -f "$known" >/dev/null 2>&1 || true
  printf '[%s]:%s %s\n' "$ip" "$port" "$hk" >>"$known"
  printf 'user=%s\n' "$user" >"$HOME/.android/channel-$host.conf"
  a shell "rm -rf $d" >/dev/null 2>&1 || true
  say "   pinned the host key; the channel user is $user"

  say "-- start Shizuku"
  shizuku_start_adb || say "   could not start Shizuku over adb: open Shizuku, Start via wireless debugging (pairs in-app once)"

  say "-- verify"
  local t=$transport
  if [ -n "${dry:-}" ] || ssh_connect "$ip"; then
    transport=ssh
    say "   sshd answers on $ip:$port. On the phone: allow Termux in the Shizuku dialog (shown once, the first time rish runs)."
    if poll "${wait_s:-900}" priv_ok; then
      say "   ok: the channel is up and privileged (Shizuku). android $dev now goes over ssh first."
    else
      transport=$t
      say "   sshd works, but rish did not get Shizuku permission in time: open Shizuku, Authorized applications, allow Termux, then run: android $dev" >&2
      return 10
    fi
    transport=$t
  else
    say "error: the setup finished but sshd does not answer on $ip:$port (the phone is not on the tailnet, or the ACL blocks it)" >&2
    return 10
  fi
}

main "$@"
