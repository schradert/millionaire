#!/usr/bin/env bash
# Scaffold a new app ("purpose") from templates/app and register it in the
# workspace. Invoked via the `new-app` devenv script. See ../../TARGETS.md
# and ../../README.md for the layer model.
set -euo pipefail

ROOT="${DEVENV_ROOT:-$PWD}"
TEMPLATES="$ROOT/templates"
CARGO_TOML="$ROOT/Cargo.toml"

# First positional is the app name (unless it's a flag). Anything after is
# forwarded to cargo-generate (e.g. `-d runtime=both --silent` for scripted use).
name=""
if [ "${1:-}" ] && [ "${1#-}" = "$1" ]; then name="$1"; shift; fi
if [ -z "$name" ]; then
  read -rp "App name (kebab-case, no homelab- prefix): " name
fi
name="${name#homelab-}"   # tolerate a pasted homelab- prefix

if ! printf '%s' "$name" | grep -qE '^[a-z][a-z0-9-]*$'; then
  echo "error: app name must be kebab-case (^[a-z][a-z0-9-]*\$): '$name'" >&2
  exit 1
fi
if [ -e "$ROOT/apps/$name" ]; then
  echo "error: apps/$name already exists" >&2
  exit 1
fi

cargo generate \
  --path "$TEMPLATES/app" \
  --destination "$ROOT/apps" \
  --name "$name" \
  --vcs none "$@"

# Apps are EXCLUDED from workspace membership (so cargo doesn't feature-unify
# a chip-agnostic lib across boards targeting different chips). Insert the new
# path just above the exclude-list marker.
tmp="$(mktemp)"
awk -v ins="  \"apps/$name\"," '
  index($0, "new-app/new-board(avr): excluded") && !done { print ins; done=1 }
  { print }
' "$CARGO_TOML" > "$tmp"
mv "$tmp" "$CARGO_TOML"

snake="${name//-/_}"
cat <<EOF

✓ created apps/$name  (crate: homelab-$name)
  • added "apps/$name" to [workspace] exclude
  • use it from a board crate's Cargo.toml:
      homelab-$name = { path = "../../apps/$name", features = ["embassy"] }
  • and call it from main.rs:
      homelab_${snake}::run_async(...)    # or run_blocking(delay, ...)
EOF
