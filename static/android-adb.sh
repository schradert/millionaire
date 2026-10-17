#!/usr/bin/env bash
# Runs on a tailnet host, piped over ssh by `android` (devenv.nix) inside a
# `nix shell` with adb, nmap, curl and jq (or locally, with `dry=1`, against stubs that print what would
# run). Finds the phone's wireless-debugging port, connects with this host's paired adb key and prints
# the device state as `key value` lines. The caller prepends variables (printf %q):
#   link    opens that Obtainium import on the phone, which asks for confirmation
#   spec    android.devices.<d>.productivity as JSON: adds `prod ok|DRIFT <check>` audit lines
#   st_key  Syncthing's GUI API key for that device (derived from its identity), for the audit's REST calls
#   dev     the device name (for the instructions in error messages)
#   pair_addr, pair_code   `android <device> pair <ip:port> <code>`: pair this host's key with the phone first
#                      (Wireless debugging > Pair device with pairing code; the code arrives here, never in an argument list)
#   act=productivity   configure the notes and calendar apps instead (`stages`: syncthing orgzly davx5 fossify;
#                      zip_b64: the Syncthing import archive; dav_pass: the Baikal password; dry=1: print only;
#                      wait_s: how long each tap is awaited, default 600). Each app is its own stage: one failing or
#                      timing out never stops the others, a summary table closes the run and the exit status is non-zero
#                      unless every stage is ok.
# Secrets arrive on stdin or in these variables, never in an argument list.

dry_stubs() {
  # a stand-in phone: every read finds nothing installed, every write is printed (stdin masked)
  exec 9>&2 # the callers redirect stdout and stderr; the printed commands must still show
  tailscale() { echo 100.64.0.99; }
  # stub=noport (nothing open), stub=unpaired (a port is open, adb connect fails), stub=nolaunch (no launcher intent
  # resolves; monkey still works) and stub=nolaunch-all (monkey fails too) test the error paths
  nmap() { [ "${stub:-}" = noport ] || echo "Host: 100.64.0.99 ()	Ports: 37000/open/tcp//unknown///"; }
  curl() { return 7; }
  sleep() { :; }
  adb() {
    local args=("$@") n
    [ "${args[0]:-}" = -s ] && args=("${args[@]:2}")
    case "${args[*]}" in
      devices) [ -n "${stub:-}" ] || printf 'List of devices attached\n100.64.0.99:37000\tdevice\n'; return ;;
      pair*) cat >/dev/null; [ "${stub:-}" = badcode ] && echo "Failed: Wrong password or connection was dropped" || echo "Successfully paired to ${args[1]} [guid=adb-stub]"; return ;;
      connect*) if [ "${stub:-}" = unpaired ]; then echo "failed to connect to '${args[1]}'"; else echo "connected to ${args[1]}"; fi; return ;;
      "shell getprop ro.build.version.release") echo 17; return ;;
      "shell settings get"*) echo null; return ;;
      "shell pm list packages"*|"shell dumpsys"*|"shell appops get"*|"shell content query"*) return 0 ;;
      "shell pm path"*|"shell test"*) return 1 ;;
      "forward tcp:0 tcp:8384") echo 38384; return ;;
      "shell monkey"*) [ "${stub:-}" != nolaunch-all ] || return 1 ;;
      "shell am start"*) if [[ "${stub:-}" == nolaunch* ]]; then echo "Error: Activity not started, unable to resolve Intent { ${args[*]} }"; return 255; fi ;;
      "shell cmd package resolve-activity"*) [[ "${stub:-}" == nolaunch* ]] || echo "com.example/.Main"; return ;;
    esac
    n=""
    [ ! -p /dev/stdin ] || n=" <<< stdin: $(wc -c | tr -d ' ') bytes, masked"
    printf '+ adb %s%s\n' "${args[*]}" "$n" >&9
  }
}

serial=""
zip_pushed=""
# the Syncthing archive holds a private key: remove it however the run ends
cleanup() { [ -z "$zip_pushed" ] || adb -s "$serial" shell rm -f "$zip_pushed" </dev/null >/dev/null 2>&1 || true; }

main() {
  set -euo pipefail
  local host=$1 ip port s out
  local ports=""

  trap cleanup EXIT
  [ -z "${dry:-}" ] || dry_stubs
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
  a() { adb -s "$serial" "$@" </dev/null; }
  echo "serial $serial"
  s=$serial
  echo "release $(a shell getprop ro.build.version.release)"
  if [ "${act:-status}" = productivity ]; then
    productivity "$serial"
    return
  fi
  echo "vpn_app $(a shell settings get secure always_on_vpn_app)"
  echo "vpn_lockdown $(a shell settings get secure always_on_vpn_lockdown)"
  a shell pm list packages -3 -i | sed -n 's/^package:\([^ ]*\) *installer=\(.*\)$/pkg \1 \2/p'
  if [ -n "${link:-}" ]; then
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
st_open() { st_port=$(adb -s "$1" forward tcp:0 tcp:8384 </dev/null 2>/dev/null) || st_port=""; }
st_close() { [ -z "${st_port:-}" ] || adb -s "$1" forward --remove "tcp:$st_port" </dev/null >/dev/null 2>&1 || true; }
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

audit() {
  local s=$1 id hub org ver st dir accts cals pkg apps
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
  grant "$pkg" POST_NOTIFICATIONS READ_CALENDAR WRITE_CALENDAR
  accounts=$(dav_accounts)
  if [ -n "$accounts" ]; then
    say "   account exists ($(tr '\n' ' ' <<<"$accounts")); tick the $(sp .caldav.calendar) calendar in the account if the audit says it is not synced"
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
  say "   then in the account tick the '$(sp .caldav.calendar)' calendar (DAVx5 preselects none)."
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
    note "account created, calendar synced"
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

main "$@"
