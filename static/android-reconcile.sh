# shellcheck shell=bash disable=SC2154 # want, state, cache, ... come from the caller
# Function library, concatenated in front of static/android-adb.sh by `android` (devenv.nix) and by bonobo's timer
# (static/android-reconcile.nix); it defines functions only. `act=reconcile` makes the phone match the catalog:
# resolve each app's newest APK the way Obtainium does, push it over the channel and install it silently with
# Shizuku's shell (`pm install`, no prompt). Header variables (printf %q, see android-adb.sh):
#   want      android.devices.<d> as JSON (the catalog entries of the device: .apps[] with url and additionalSettings)
#   only      space-separated package ids: reconcile only these (the channel bootstrap uses it)
#   plan      non-empty: resolve and compare only, install nothing (`android <d> reconcile --plan`)
#   state     JSON file of what was installed from which release (default ~/.android/reconcile-<dev>.json)
#   cache     download and HTTP cache directory (default ~/.cache/android-reconcile)
#   gh_token  GitHub token (optional: without it the API allows 60 requests an hour per address; ETag revalidation
#             keeps a steady-state run inside that, the first run over a big catalog takes several)
#   ntfy, ntfy_token_file   post the outcome to this topic URL when it changed since the last run
# Never uninstalls, never falls back to a prompt: when Shizuku is down the apps stay `pending` and the exit status is 5.

rc_state() { printf '%s' "${state:-$HOME/.android/reconcile-${dev:-device}.json}"; }
rc_cache() { printf '%s' "${cache:-${XDG_CACHE_HOME:-$HOME/.cache}/android-reconcile}"; }

# http_get <url>: the body on stdout. 75 when rate limited, 22 on any other HTTP error. Revalidates with the ETag, so a
# 304 is answered from the cache (and does not count against GitHub's rate limit).
http_get() {
  local url=$1 dir key etag="" code tok=""
  dir=$(rc_cache)/http
  mkdir -p "$dir"
  key=$(printf '%s' "$url" | sha256sum | cut -c1-32)
  if [ -f "$dir/$key.etag" ] && [ -f "$dir/$key.body" ]; then etag=$(cat "$dir/$key.etag"); fi
  if [[ "$url" == https://api.github.com/* ]]; then tok=${gh_token:-$(cat "$HOME/.android/github-token" 2>/dev/null || true)}; fi
  code=$(curl -sSL --max-time 60 -o "$dir/$key.new" -D "$dir/$key.hdr" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' ${etag:+-H "If-None-Match: $etag"} \
    ${tok:+-K <(printf 'header = "Authorization: Bearer %s"\n' "$tok")} "$url") || return 22
  case $code in
    200)
      mv "$dir/$key.new" "$dir/$key.body"
      sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$dir/$key.hdr" | tr -d '\r' | tail -1 >"$dir/$key.etag"
      cat "$dir/$key.body"
      ;;
    304) cat "$dir/$key.body" ;;
    403 | 429) return 75 ;;
    *) return 22 ;;
  esac
}

# resolve <app json> <abi>: one JSON line {tag, file, url, vc} for the APK Obtainium would install, or a reason on
# stderr and status 1 (unresolvable) / 75 (rate limited). The app's additionalSettings give the filters:
# apkFilterRegEx (+ invertAPKFilter), includePrereleases, fallbackToOlderReleases.
resolve() {
  local app=$1 abi=$2 url id st body rc=0 repo base api
  url=$(jq -r .url <<<"$app")
  id=$(jq -r .id <<<"$app")
  st=$(jq -c '(.additionalSettings | fromjson? // {})' <<<"$app")
  case $url in
    https://github.com/*/*)
      repo=$(sed -E 's#^https://github\.com/([^/]+/[^/]+).*#\1#; s#\.git$##' <<<"$url")
      body=$(http_get "https://api.github.com/repos/$repo/releases?per_page=20") || rc=$?
      [ "$rc" -eq 0 ] || { echo "GitHub releases of $repo: HTTP error (rate limited? put a token in ~/.android/github-token)" >&2; return "$rc"; }
      jq -c --argjson st "$st" --arg abi "$abi" '
        def tokens: ["arm64-v8a", "arm64", "aarch64", "armeabi-v7a", "armeabi", "armv7", "x86_64", "x86", "i386"];
        def mine: if $abi == "arm64-v8a" then ["arm64-v8a", "arm64", "aarch64"]
                  elif $abi == "armeabi-v7a" then ["armeabi-v7a", "armeabi", "armv7"]
                  else [$abi] end;
        def rank($n): ($n | ascii_downcase) as $l
          | if (mine | any(. as $t | $l | contains($t))) then 0
            elif (tokens | any(. as $t | $l | contains($t))) then 9
            else 1 end;
        ($st.apkFilterRegEx // "") as $f
        | ($st.invertAPKFilter // false) as $inv
        | ($st.includePrereleases // false) as $pre
        | ($st.fallbackToOlderReleases // true) as $fb
        | [ .[] | select(.draft | not) | select($pre or (.prerelease | not))
            | { tag: .tag_name,
                apks: [ .assets[] | select(.name | test("\\.apk$"; "i"))
                        | select(($f == "") or ((try (.name | test($f; "i")) catch false) != $inv)) ] } ]
        | (if $fb then map(select(.apks | length > 0)) else .[:1] end)
        | first // empty
        | . as $r
        | ($r.apks | map(. + {rank: rank(.name)}) | map(select(.rank < 9)) | sort_by(.rank, (.name | length))) as $c
        | select($c | length > 0)
        | {tag: $r.tag, file: $c[0].name, url: $c[0].browser_download_url, vc: null}' <<<"$body" | grep -m1 . \
        || { echo "no APK in the newest GitHub releases of $repo matches the filters for $abi" >&2; return 1; }
      ;;
    https://f-droid.org/packages/* | https://apt.izzysoft.de/fdroid/index/apk/*)
      if [[ "$url" == https://f-droid.org/* ]]; then
        api=https://f-droid.org/api/v1/packages/$id
        base=https://f-droid.org/repo
      else
        api=https://apt.izzysoft.de/fdroid/api/v1/packages/$id
        base=https://apt.izzysoft.de/fdroid/repo
      fi
      body=$(http_get "$api") || rc=$?
      [ "$rc" -eq 0 ] || { echo "$api: HTTP error" >&2; return "$rc"; }
      jq -c --arg id "$id" --arg base "$base" '
        (.suggestedVersionCode // ((.packages // []) | map(.versionCode) | max)) as $vc
        | select($vc != null)
        | {tag: (first(.packages[]? | select(.versionCode == $vc) | .versionName) // ($vc | tostring)),
           file: "\($id)_\($vc).apk", url: "\($base)/\($id)_\($vc).apk", vc: $vc}' <<<"$body" | grep -m1 . \
        || { echo "$api lists no version of $id" >&2; return 1; }
      ;;
    https://*)
      # a direct APK link has no version to compare: installed once, then left alone
      jq -cn --arg url "$url" '{tag: "direct", file: ($url | split("/") | last), url: $url, vc: null}'
      ;;
    *)
      echo "unsupported source $url" >&2
      return 1
      ;;
  esac
}

# norm <version>: what a release tag and an installed versionName have in common (v1.2.3 / 1.2.3 / 1.2.3-fdroid)
norm() { printf '%s' "$1" | sed -E 's/^[^0-9]*//; s/[-+_ ].*$//'; }

# phone_state: "package versionCode versionName" of every third-party package, from one shell call
phone_state() {
  # shellcheck disable=SC2016 # for the phone's shell
  a shell 'for p in $(pm list packages -3 | cut -d: -f2 | tr -d "\r"); do
    echo "$p $(dumpsys package "$p" | sed -n "s/^ *versionCode=\([0-9]*\).*/\1/p;s/^ *versionName=//p" | head -2 | tr "\n" " ")"
  done' 2>/dev/null || true
}

# reconcile: the whole run. Prints "status id detail" lines and a summary; exit 0 converged, 2 failures left,
# 5 pending (Shizuku down). Callers set `priv` (up|down) beforehand.
reconcile() {
  local abi st apps have n=0 ok=0 inst=0 fail=0 unres=0 pend=0 app id tag res file url vc cur curvc curvn rc line sum tmp err
  local stage=/sdcard/Download/.android-reconcile
  local -a report=()
  st=$(rc_state)
  mkdir -p "$(dirname "$st")" "$(rc_cache)/apk"
  [ -s "$st" ] || echo '{}' >"$st"
  err=$(rc_cache)/err.$$
  abi=$(a shell getprop ro.product.cpu.abilist 2>/dev/null | tr ',' '\n' | head -1 | tr -d '\r' || true)
  abi=${abi:-arm64-v8a}
  have=$(phone_state)
  apps=$(jq -c '.apps[]' <<<"$want")
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    id=$(jq -r .id <<<"$app")
    if [ -n "${only:-}" ] && [[ " $only " != *" $id "* ]]; then continue; fi
    n=$((n + 1))
    line=$(grep -F "$id " <<<"$have" | grep "^$id " | head -1 || true)
    curvc=$(awk '{print $2}' <<<"$line")
    curvn=$(awk '{print $3}' <<<"$line")
    rc=0
    res=$(resolve "$app" "$abi" 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 75 ]; then
        report+=("deferred   $id: GitHub rate limit, next run")
        pend=$((pend + 1))
      else
        report+=("unresolved $id: $(cat "$err")")
        unres=$((unres + 1))
      fi
      continue
    fi
    tag=$(jq -r .tag <<<"$res")
    file=$(jq -r .file <<<"$res")
    url=$(jq -r .url <<<"$res")
    vc=$(jq -r '.vc // empty' <<<"$res")
    cur=$(jq -r --arg id "$id" '.[$id].tag // empty' "$st")
    # up to date? F-Droid: the version code. GitHub: the recorded release, else the installed versionName against the tag.
    if [ -n "$line" ]; then
      if [ -n "$vc" ] && [ "${curvc:-0}" -ge "$vc" ] 2>/dev/null; then ok=$((ok + 1)); continue; fi
      if [ -z "$vc" ] && { [ "$tag" = direct ] || [ "$cur" = "$tag" ]; }; then ok=$((ok + 1)); continue; fi
      if [ -z "$vc" ] && [ -n "$curvn" ] && [ "$(norm "$curvn")" = "$(norm "$tag")" ]; then
        jq --arg id "$id" --arg tag "$tag" '.[$id] = {tag: $tag, seeded: true}' "$st" >"$st.new" && mv "$st.new" "$st"
        ok=$((ok + 1))
        continue
      fi
    fi
    if [ -n "${plan:-}" ]; then
      report+=("would-install $id: $tag (${curvn:-not installed} now)")
      continue
    fi
    if [ "${priv:-up}" != up ]; then
      report+=("pending    $id: $tag waits for Shizuku (${curvn:-not installed} now)")
      pend=$((pend + 1))
      continue
    fi
    # download, push, install
    tmp=$(rc_cache)/apk/$id/$tag
    mkdir -p "$tmp"
    if [ ! -s "$tmp/$file" ]; then
      if ! curl -fsSL --retry 3 --max-time 1800 -o "$tmp/$file.part" "$url"; then
        report+=("FAILED     $id: download of $url failed")
        fail=$((fail + 1))
        continue
      fi
      mv "$tmp/$file.part" "$tmp/$file"
    fi
    a shell "mkdir -p $stage" >/dev/null 2>&1 || true
    if ! push_file "$tmp/$file" "$stage/$id.apk"; then
      report+=("FAILED     $id: could not push the APK to the phone")
      fail=$((fail + 1))
      continue
    fi
    # Android 17: system_server may not read shared storage (fuse; "Unable to open file: /sdcard/..." from pm install), so
    # the shell copies the APK to /data/local/tmp, which it can both write and system_server can read
    # installer of record = Obtainium, so it still sees the app as its own (Android 12+ lets it update those silently)
    sum=$(a shell "cp '$stage/$id.apk' /data/local/tmp/$id.apk && pm install -r -i dev.imranr.obtainium --user 0 '/data/local/tmp/$id.apk'" 2>&1 | tr -d '\r' | grep -m3 -E 'Success|Failure|Error|Exception|cp:' | tr '\n' ' ') || true
    a shell "rm -f '$stage/$id.apk' '/data/local/tmp/$id.apk'" >/dev/null 2>&1 || true
    # keep only the newest download of each app
    find "$(rc_cache)/apk/$id" -mindepth 1 -maxdepth 1 ! -name "$tag" -exec rm -rf {} + 2>/dev/null || true
    case $sum in
      *Success*)
        jq --arg id "$id" --arg tag "$tag" '.[$id] = {tag: $tag}' "$st" >"$st.new" && mv "$st.new" "$st"
        report+=("installed  $id: $tag (was ${curvn:-not installed})")
        inst=$((inst + 1))
        ;;
      *INSTALL_FAILED_VERSION_DOWNGRADE*)
        jq --arg id "$id" --arg tag "$tag" '.[$id] = {tag: $tag, newer_installed: true}' "$st" >"$st.new" && mv "$st.new" "$st"
        ok=$((ok + 1))
        ;;
      *INSTALL_FAILED_UPDATE_INCOMPATIBLE* | *INSTALL_FAILED_SHARED_USER_INCOMPATIBLE*)
        report+=("FAILED     $id: signed differently from the installed copy; uninstall it by hand (its data goes) to switch to $tag")
        fail=$((fail + 1))
        ;;
      *)
        report+=("FAILED     $id: pm install said: ${sum:-nothing}")
        fail=$((fail + 1))
        ;;
    esac
  done <<<"$apps"
  rm -f "$err"
  a shell "rmdir '$stage'" >/dev/null 2>&1 || true
  echo "== reconcile ${dev:-device}: $n apps, $ok up to date, $inst installed, $fail failed, $unres unresolved, $pend pending"
  if [ "${#report[@]}" -gt 0 ]; then printf '%s\n' "${report[@]}"; fi
  if [ -z "${plan:-}" ]; then rc_notify "$n" "$inst" "$fail" "$unres" "$pend" "${report[@]+"${report[@]}"}"; fi
  if [ "$pend" -gt 0 ] && [ "${priv:-up}" != up ]; then return 5; fi
  if [ "$fail" -gt 0 ] || [ "$unres" -gt 0 ]; then return 2; fi
  return 0
}

# rc_notify <n> <installed> <failed> <unresolved> <pending> <lines...>: ntfy, only when the set of problems changed
# (or something was installed), so an hourly timer does not repeat itself
rc_notify() {
  local n=$1 inst=$2 fail=$3 unres=$4 pend=$5 hash last f title prio=default
  shift 5
  [ -n "${ntfy:-}" ] || return 0
  f=$(rc_cache)/last-report.${dev:-device}
  hash=$(printf '%s\n' "$fail $unres $pend" "$(printf '%s\n' "$@" | grep -E '^(FAILED|unresolved|pending)' | sort || true)" | sha256sum | cut -c1-16)
  last=$(cat "$f" 2>/dev/null || true)
  if [ "$inst" -eq 0 ] && { [ "$hash" = "$last" ] || [ $((fail + unres + pend)) -eq 0 ]; }; then
    printf '%s' "$hash" >"$f"
    return 0
  fi
  printf '%s' "$hash" >"$f"
  title="android ${dev:-device}: $inst installed"
  if [ $((fail + unres + pend)) -gt 0 ]; then title="$title, $fail failed, $unres unresolved, $pend pending"; fi
  if [ $((fail + unres)) -gt 0 ]; then prio=high; fi
  curl -sS --max-time 20 -o /dev/null ${ntfy_token_file:+-K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$ntfy_token_file")")} \
    -H "Title: $title" -H "Priority: $prio" -d "$(printf '%s\n' "$@" | head -40)" "$ntfy" || echo "ntfy post failed" >&2
}
