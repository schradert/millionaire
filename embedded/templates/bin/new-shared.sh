#!/usr/bin/env bash
# Scaffold a new shared capability ("tier") library from templates/shared and
# register it in the workspace. Invoked via the `new-shared` devenv script.
# See ../../TARGETS.md for the tier model.
set -euo pipefail

ROOT="${DEVENV_ROOT:-$PWD}"
TEMPLATES="$ROOT/templates"
CARGO_TOML="$ROOT/Cargo.toml"

# First positional is the lib name (unless it's a flag). Anything after is
# forwarded to cargo-generate (e.g. `-d description=... --silent`).
name=""
if [ "${1:-}" ] && [ "${1#-}" = "$1" ]; then name="$1"; shift; fi
if [ -z "$name" ]; then
  read -rp "Shared lib name (kebab-case, no homelab-shared- prefix): " name
fi
name="${name#homelab-shared-}"   # tolerate a pasted prefix
name="${name#homelab-}"

if ! printf '%s' "$name" | grep -qE '^[a-z][a-z0-9-]*$'; then
  echo "error: name must be kebab-case (^[a-z][a-z0-9-]*\$): '$name'" >&2
  exit 1
fi
if [ -e "$ROOT/shared/$name" ]; then
  echo "error: shared/$name already exists" >&2
  exit 1
fi

cargo generate \
  --path "$TEMPLATES/shared" \
  --destination "$ROOT/shared" \
  --name "$name" \
  --vcs none "$@"

# Shared libs are EXCLUDED from workspace membership (consumed by path), so
# insert just above the exclude-list marker.
tmp="$(mktemp)"
awk -v ins="  \"shared/$name\"," '
  index($0, "new-app/new-board(avr): excluded") && !done { print ins; done=1 }
  { print }
' "$CARGO_TOML" > "$tmp"
mv "$tmp" "$CARGO_TOML"

cat <<EOF

✓ created shared/$name  (crate: homelab-shared-$name)
  • added "shared/$name" to [workspace] exclude
  • use it from a board or app:
      homelab-shared-$name = { path = "../../shared/$name" }
  • add the capability's own deps to shared/$name/Cargo.toml (explicit versions)
EOF
