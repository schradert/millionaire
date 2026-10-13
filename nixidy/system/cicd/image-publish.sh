set -euo pipefail
# usage: image-publish.sh plan  <repo-url> <revision> <only> <force>
#        image-publish.sh build <repo-url> <name@tag>
#        image-publish.sh verdict <items.json> <blocked.json>
#
# plan  : for the revision and every recent commit that could have changed an
#         image tag, list the images whose <name>:<tag> is missing from Harbor.
#         Writes a JSON array of "name@tag" to /tmp/items.json, and the ones it
#         gave up on (too many failed builds) to /tmp/blocked.json.
# build : build and push one "name@tag". Each runs as its own workflow step
#         (continueOn failed), so one broken image does not block the others.
# verdict: runs last and fails the workflow unless every planned image was
#         pushed and nothing is blocked, so a broken image never reads as
#         published. An image counts as pushed once build() removes its plan file.
STATE=/nix/.image-publish
FLAKE_IMAGES=".#legacyPackages.x86_64-linux.images"
MAX_TRIES=3
MAX_COMMITS=15
mkdir -p "$STATE" /etc/nix
# The nix image ships nix.conf as a symlink into /nix/store, which our
# /nix cache volume may not contain; replace it with a plain file.
rm -f /etc/nix/nix.conf
cat > /etc/nix/nix.conf <<NIXCONF
build-users-group = nixbld
experimental-features = nix-command flakes
sandbox = false
filter-syscalls = false
accept-flake-config = true
max-jobs = auto
cores = 0
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
NIXCONF

# prints the HTTP status of <repo>:<tag> in Harbor (200 present, 404 missing)
registry_code() {
  local repo="$1" tag="$2" registry path
  registry=${repo%%/*}; path=${repo#*/}
  curl -s -m 30 -o /dev/null -w '%{http_code}' \
    "https://$registry/api/v2.0/projects/${path%%/*}/repositories/${path#*/}/artifacts/$tag" || true
}

# a file of lines as a JSON array of strings
json_list() {
  local json="" item
  while read -r item; do json="$json${json:+,}\"$item\""; done < "$1"
  echo "[$json]"
}

plan() {
  local REPO="$1" REF="$2" ONLY="$3" FORCE="$4" rev="" explicit=0
  echo '[]' > /tmp/items.json; echo '[]' > /tmp/blocked.json
  case "$REF" in
    [0-9a-f]*) if [ "${#REF}" -eq 40 ]; then rev="$REF"; explicit=1; fi ;;
  esac
  [ -n "$rev" ] || rev=$(git ls-remote "$REPO" "refs/heads/$REF" | cut -f1)
  [ -n "$rev" ] || { echo "cannot resolve $REF in $REPO" >&2; exit 1; }
  echo "revision: $rev"
  if [ "$(cat "$STATE/clean-sha" 2>/dev/null || true)" = "$rev" ] && [ "$FORCE" != true ] && [ -z "$ONLY" ]; then
    if [ -s "$STATE/blocked" ]; then
      echo "images of $rev already inspected, but still blocked:"; cat "$STATE/blocked"
      json_list "$STATE/blocked" > /tmp/blocked.json
    else
      echo "all images of $rev already published, nothing to do"
    fi
    return 0
  fi

  local work; work=$(mktemp -d); cd "$work"
  git init -q .
  git fetch -q --depth 200 "$REPO" "$rev"
  git checkout -q --detach FETCH_HEAD

  # Every commit since the last fully published one that touched an image's
  # inputs, oldest first, then the tip: a tag bumped in an intermediate commit
  # is built at that commit even if a later commit moved the tag again.
  local revs="$rev" base=""
  if [ "$explicit" = 0 ] && [ -z "$ONLY" ]; then
    base=$(cat "$STATE/clean-sha" 2>/dev/null || true)
    if [ -n "$base" ] && git cat-file -e "$base^{commit}" 2>/dev/null; then
      revs=$(git rev-list --first-parent --reverse -n "$MAX_COMMITS" "$base..$rev" -- modules/images.nix apps flake.lock pkgs || true)
    else
      echo "no previous full publish recorded, inspecting the tip only"
    fi
    echo "$revs" | grep -q "^$rev\$" || revs=$(printf '%s\n%s' "$revs" "$rev")
    revs=$(echo "$revs" | grep -v '^$')
  fi
  echo "commits to inspect: $(echo "$revs" | wc -l)"

  : > "$work/items"; : > "$work/seen"; : > "$work/blocked"
  local unknown=0 c list name repo tag code key tries
  for c in $revs; do
    git checkout -q --detach "$c"
    if ! list=$(nix eval --no-pure-eval --raw "$FLAKE_IMAGES" --apply \
      'i: builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (n: v: n + " " + v.imageName + " " + v.imageTag) i))'); then
      echo "[${c:0:8}] cannot evaluate images" >&2
      [ "$c" = "$rev" ] && exit 1
      unknown=1; continue
    fi
    while read -r name repo tag; do
      [ -n "$name" ] || continue
      if [ -n "$ONLY" ] && ! echo ",$ONLY," | grep -q ",$name,"; then continue; fi
      key="$name@$tag"
      grep -qxF "$key" "$work/seen" && continue
      echo "$key" >> "$work/seen"
      code=$(registry_code "$repo" "$tag")
      if [ "$code" = 200 ]; then echo "[$key] in registry (${c:0:8})"; continue; fi
      if [ "$code" != 404 ]; then echo "[$key] registry check returned HTTP $code" >&2; unknown=1; continue; fi
      tries=$(cat "$STATE/tries-$name-$tag" 2>/dev/null || echo 0)
      if [ "$FORCE" != true ] && [ "$tries" -ge "$MAX_TRIES" ]; then
        echo "[$key] GIVING UP after $tries failed builds (force=true retries)" >&2
        echo "$key" >> "$work/blocked"; continue
      fi
      echo "[$key] missing, will build from ${c:0:8}"
      echo "$c $repo" > "$STATE/plan-$name-$tag"
      echo "$key" >> "$work/items"
    done <<LIST
$list
LIST
  done

  json_list "$work/items" > /tmp/items.json
  json_list "$work/blocked" > /tmp/blocked.json
  echo "to build: $(cat /tmp/items.json)"
  # Blocked images are remembered with the sha, so later polls of it keep failing
  # (cheaply) instead of reading as "already published".
  if [ ! -s "$work/items" ] && [ "$unknown" = 0 ] && [ "$explicit" = 0 ] && [ -z "$ONLY" ]; then
    echo "$rev" > "$STATE/clean-sha"; cp "$work/blocked" "$STATE/blocked"
  fi
}

build() {
  local REPO="$1" key="$2" name tag rev repo work out tries
  name=${key%@*}; tag=${key#*@}
  read -r rev repo < "$STATE/plan-$name-$tag"
  if [ "$(registry_code "$repo" "$tag")" = 200 ]; then
    rm -f "$STATE/plan-$name-$tag"; echo "[$key] already in registry"; return 0
  fi
  work=$(mktemp -d); cd "$work"
  git init -q .
  git fetch -q --depth 1 "$REPO" "$rev"
  git checkout -q --detach FETCH_HEAD
  echo "[$key] building from ${rev:0:8}"
  if out=$(nix build --no-pure-eval --no-link --print-out-paths -L "$FLAKE_IMAGES.$name.copyToRegistry") \
    && "$out/bin/copy-to-registry"; then
    rm -f "$STATE/tries-$name-$tag" "$STATE/plan-$name-$tag"
    echo "[$key] pushed $repo:$tag"
  else
    tries=$(cat "$STATE/tries-$name-$tag" 2>/dev/null || echo 0)
    echo $((tries + 1)) > "$STATE/tries-$name-$tag"
    echo "[$key] FAILED (attempt $((tries + 1)) of $MAX_TRIES)" >&2
    exit 1
  fi
}

# fails unless every planned image was pushed and none is blocked
verdict() {
  local key name tag bad=0
  for key in $(echo "$1" | tr -d '[]"' | tr ',' ' '); do
    name=${key%@*}; tag=${key#*@}
    if [ -e "$STATE/plan-$name-$tag" ]; then
      echo "[$key] NOT published" >&2; bad=1
    else
      echo "[$key] published"
    fi
  done
  for key in $(echo "$2" | tr -d '[]"' | tr ',' ' '); do
    echo "[$key] BLOCKED: given up after $MAX_TRIES failed builds, not published (force=true retries)" >&2; bad=1
  done
  [ "$bad" = 0 ] || { echo "image-publish FAILED: see the lines above" >&2; exit 1; }
  echo "every image published"
}

mode="$1"; shift
case "$mode" in
  plan | build | verdict) "$mode" "$@" ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
