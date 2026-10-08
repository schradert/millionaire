set -euo pipefail
REPO="$1"; REF="$2"; ONLY="$3"; FORCE="$4"
STATE=/nix/.image-publish
mkdir -p "$STATE" /etc/nix
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

# Resolve REF (branch name or full sha) to a commit sha.
case "$REF" in
  [0-9a-f]*) [ "${#REF}" -eq 40 ] && rev="$REF" || rev="" ;;
  *) rev="" ;;
esac
if [ -z "$rev" ]; then
  rev=$(git ls-remote "$REPO" "refs/heads/$REF" | cut -f1)
fi
[ -n "$rev" ] || { echo "cannot resolve $REF in $REPO" >&2; exit 1; }
echo "revision: $rev"

if [ -e "$STATE/done-$rev" ] && [ "$FORCE" != "true" ] && [ -z "$ONLY" ]; then
  echo "already published $rev, nothing to do"
  exit 0
fi

work=$(mktemp -d)
cd "$work"
git init -q .
git fetch -q --depth 1 "$REPO" "$rev"
git checkout -q FETCH_HEAD

FLAKE_IMAGES=".#legacyPackages.x86_64-linux.images"
list=$(nix eval --no-pure-eval --raw "$FLAKE_IMAGES" --apply \
  'i: builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (n: v: n + " " + v.imageName + " " + v.imageTag) i))')
echo "images defined at $rev:"; echo "$list"

failed=0
while read -r name repo tag; do
  [ -n "$name" ] || continue
  if [ -n "$ONLY" ] && ! echo ",$ONLY," | grep -q ",$name,"; then continue; fi
  # repo = <registry>/<project>/<repository>
  registry=${repo%%/*}; path=${repo#*/}; project=${path%%/*}; rname=${path#*/}
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    "https://$registry/api/v2.0/projects/$project/repositories/$rname/artifacts/$tag")
  if [ "$code" = 200 ]; then echo "[$name] $tag already in registry, skipping"; continue; fi
  if [ "$code" != 404 ]; then echo "[$name] registry check returned HTTP $code" >&2; failed=1; continue; fi
  echo "[$name] building $tag"
  if out=$(nix build --no-pure-eval --no-link --print-out-paths -L "$FLAKE_IMAGES.$name.copyToRegistry"); then
    echo "[$name] pushing $repo:$tag"
    if "$out/bin/copy-to-registry"; then echo "[$name] pushed"; else failed=1; fi
  else
    echo "[$name] build failed" >&2; failed=1
  fi
done <<LIST
$list
LIST

[ "$failed" = 0 ] || { echo "some images failed" >&2; exit 1; }
[ -n "$ONLY" ] || touch "$STATE/done-$rev"
echo done
