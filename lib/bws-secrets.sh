#!/usr/bin/env bash
# Install the secrets listed in the manifest ($BWS_SECRETS_MANIFEST, built by modules/bws-secrets.nix)
# from Bitwarden Secrets Manager. Design: docs/secrets.md.
#   sync     fetch everything with the host's machine token, refresh the encrypted cache, install;
#            when Bitwarden cannot be reached, install from the cache. Exits 1 unless every secret is fresh.
#   restore  install from the cache only (activation, before the network is up). Never fails.
# The cache is age-encrypted to the host's ssh ed25519 key, so a disk image alone does not reveal it.
set -euo pipefail

mode=${1:-}
[[ $mode == sync || $mode == restore ]] || {
  echo "usage: bws-secrets sync|restore" >&2
  exit 2
}
manifest=${BWS_SECRETS_MANIFEST:?}
token_file=${BWS_SECRETS_TOKEN_FILE:-/var/lib/bws/token}
cache_dir=${BWS_SECRETS_CACHE_DIR:-/var/lib/bws/cache}
host_key=${BWS_SECRETS_HOST_KEY:-/etc/ssh/ssh_host_ed25519_key}

umask 077
work=$(mktemp -d -p "${BWS_SECRETS_TMPDIR:-/run}")
trap 'rm -rf "$work"' EXIT
failed=0
warn() { echo "bws-secrets: $*" >&2; }

# $work/value -> path, atomically, with the manifest's owner, group and mode
install_value() {
  local name=$1 path=$2 owner=$3 group=$4 mode=$5 dir tmp
  [[ $mode =~ ^[0-7]{3,4}$ ]] || {
    warn "$name: bad mode '$mode'"
    return 1
  }
  dir=$(dirname "$path")
  if [ ! -d "$dir" ]; then
    [ "$dir" = /run/secrets ] || {
      warn "$name: $dir does not exist"
      return 1
    }
    install -d -m 0751 "$dir"
  fi
  tmp=$(mktemp "$dir/.$name.XXXXXX") || return 1
  if cat "$work/value" >"$tmp" && chown "$owner:$group" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$path"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# the cached value of a secret -> $work/value
from_cache() {
  [ -r "$cache_dir/$1.age" ] && [ -r "$host_key" ] && age -d -i "$host_key" -o "$work/value" "$cache_dir/$1.age" 2>/dev/null
}

fetched=0
if [ "$mode" = sync ]; then
  mkdir -p "$cache_dir"
  if [ ! -r "$token_file" ]; then
    warn "no machine token at $token_file"
  elif HOME=$work BWS_ACCESS_TOKEN=$(<"$token_file") timeout 30 bws secret list -o json >"$work/list.json" 2>"$work/err"; then
    fetched=1
  else
    warn "fetch failed: $(head -c 300 "$work/err")"
  fi
  [ "$fetched" = 1 ] || failed=1
fi

while IFS= read -r entry; do
  field() { jq -r --arg f "$1" '.[$f] // ""' <<<"$entry"; }
  name=$(field name)
  key=$(field key)
  project=$(field project)
  path=$(field path)
  if [ "$fetched" = 1 ]; then
    # a name that matches in two readable projects is ambiguous: set `project`
    if ! jq -j --arg k "$key" --arg p "$project" \
      '[.[] | select(.key == $k and ($p == "" or .projectId == $p))] | if length == 1 then .[0].value else error("\(length) secrets named \($k)") end' \
      "$work/list.json" >"$work/value" 2>"$work/err"; then
      warn "$name: $(head -c 300 "$work/err")"
      failed=1
      continue
    fi
    if [ -r "$host_key.pub" ]; then
      if ! { age -R "$host_key.pub" -o "$cache_dir/.$name.tmp" "$work/value" && mv -f "$cache_dir/.$name.tmp" "$cache_dir/$name.age"; }; then
        warn "$name: cache not written"
      fi
    else
      warn "$name: no $host_key.pub to encrypt the cache to"
    fi
  elif ! from_cache "$name"; then
    [ "$mode" = sync ] && {
      warn "$name: not fetched and not cached"
      failed=1
    }
    continue
  fi
  install_value "$name" "$path" "$(field owner)" "$(field group)" "$(field mode)" || failed=1
done < <(jq -c '.[]' "$manifest")

[ "$mode" = sync ] && exit "$failed"
exit 0
