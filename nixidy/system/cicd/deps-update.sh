set -euo pipefail
# deps-update <repo-slug> <base> <kinds>
# For each kind: fresh checkout of <base>, `update bump --only <kind>`, and
# force-push branch deps/<kind> + open (or refresh) one PR per kind.
SLUG="$1"; BASE="$2"; KINDS="$3"
mkdir -p /etc/nix
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

: "${GITHUB_TOKEN:?GITHUB_TOKEN not set}"
export GH_TOKEN="$GITHUB_TOKEN"
remote="https://x-access-token:${GITHUB_TOKEN}@github.com/${SLUG}.git"
work=$(mktemp -d)
git clone -q --branch "$BASE" "$remote" "$work/repo"
cd "$work/repo"
git config user.name "millionaire-update"
git config user.email "update@trdos.me"
tools=$(nix build --no-pure-eval --no-link --print-out-paths --inputs-from . nixpkgs#gh nixpkgs#jq | sed 's|$|/bin|' | paste -sd:)
export PATH="$tools:$PATH"
update=$(nix build --no-pure-eval --no-link --print-out-paths .#update)/bin/update
system=$(nix eval --impure --raw --expr builtins.currentSystem)
render() { nix build --no-pure-eval --no-link --print-out-paths ".#legacyPackages.$system.nixidyEnvs.$system.prod.config.build.environmentPackage"; }
gen=nixidy/generated/prod

# Copy only manifests the bump changed (raw render before vs after): the raw
# render differs cosmetically from the committed tree and skips vals.
sync_generated() {
  local before="$1" after="$2" f
  (cd "$after" && find -L . -type f -name '*.yaml') | while read -r f; do
    cmp -s "$before/$f" "$after/$f" && continue
    if grep -qE 'ref\+[a-z]+://' "$after/$f"; then echo "  skip $f (vals placeholders)"; continue; fi
    mkdir -p "$(dirname "$gen/$f")"; cp -L "$after/$f" "$gen/$f"; chmod u+w "$gen/$f"
  done
  (cd "$before" && find -L . -type f -name '*.yaml') | while read -r f; do
    [ -e "$after/$f" ] || git rm -q --ignore-unmatch "$gen/$f"
  done
}

failed=0
for kind in ${KINDS//,/ }; do
  echo "=== $kind"
  git checkout -q -f "origin/$BASE" && git clean -qfdx
  branch="deps/$kind"
  summary="$work/summary-$kind.md"
  case "$kind" in src|chart|image|flake) before=$(render) ;; *) before= ;; esac
  rc=0
  "$update" bump --only "$kind" --summary "$summary" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then echo "[$kind] update errored ($rc)" >&2; failed=1; continue; fi
  if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    echo "[$kind] nothing to update"; continue
  fi
  [ -n "$before" ] && sync_generated "$before" "$(render)"
  git checkout -q -B "$branch"
  git add -A
  git commit -q -m "chore(deps): update $kind"
  git push -q -f origin "$branch"
  body=$(printf 'Weekly `update bump --only %s`.\n\n%s\n' "$kind" "$(cat "$summary")")
  pr=$(gh pr list -R "$SLUG" --head "$branch" --base "$BASE" --state open --json number -q '.[0].number')
  if [ -n "$pr" ]; then
    gh pr edit "$pr" -R "$SLUG" --body "$body" >/dev/null
    echo "[$kind] refreshed #$pr"
  else
    gh pr create -R "$SLUG" -B "$BASE" -H "$branch" -t "chore(deps): update $kind" -b "$body"
  fi
done
exit "$failed"
