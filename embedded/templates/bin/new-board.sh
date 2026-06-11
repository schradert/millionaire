#!/usr/bin/env bash
# Scaffold a new board (binary) crate from templates/board/<kind> and register
# it in the workspace. Invoked via the `new-board` devenv script.
#
# Usage: new-board [esp32|cortex-m|avr] [name]
# Both args are prompted for if omitted.
set -euo pipefail

ROOT="${DEVENV_ROOT:-$PWD}"
TEMPLATES="$ROOT/templates"
CARGO_TOML="$ROOT/Cargo.toml"

# Positionals: [kind] [name]; both prompted if omitted. Anything after is
# forwarded to cargo-generate (e.g. `-d mcu=esp32-s3 --silent`).
kind=""
name=""
if [ "${1:-}" ] && [ "${1#-}" = "$1" ]; then kind="$1"; shift; fi
if [ "${1:-}" ] && [ "${1#-}" = "$1" ]; then name="$1"; shift; fi

if [ -z "$kind" ]; then
  echo "Board kind?"
  select k in esp32 cortex-m avr; do
    [ -n "${k:-}" ] && { kind="$k"; break; }
  done
fi
case "$kind" in
  esp32 | cortex-m | avr) ;;
  *) echo "error: kind must be one of: esp32 cortex-m avr (got '$kind')" >&2; exit 1 ;;
esac

if [ -z "$name" ]; then
  read -rp "Board crate name (kebab-case, no homelab- prefix): " name
fi
name="${name#homelab-}"
if ! printf '%s' "$name" | grep -qE '^[a-z][a-z0-9-]*$'; then
  echo "error: board name must be kebab-case (^[a-z][a-z0-9-]*\$): '$name'" >&2
  exit 1
fi
if [ -e "$ROOT/boards/$name" ]; then
  echo "error: boards/$name already exists" >&2
  exit 1
fi

cargo generate \
  --path "$TEMPLATES/board/$kind" \
  --destination "$ROOT/boards" \
  --name "$name" \
  --vcs none "$@"

# Workspace bookkeeping. esp32/cortex-m boards build with the default esp-rs
# toolchain → workspace members. AVR boards need avr-rust → excluded (built
# from their own dir via .envrc). See ../../TARGETS.md.
insert_before() { # $1 = marker substring, $2 = line to insert
  local tmp; tmp="$(mktemp)"
  awk -v marker="$1" -v ins="$2" '
    index($0, marker) && !done { print ins; done=1 }
    { print }
  ' "$CARGO_TOML" > "$tmp"
  mv "$tmp" "$CARGO_TOML"
}

if [ "$kind" = "avr" ]; then
  insert_before "new-app/new-board(avr): excluded" "  \"boards/$name\","
  membership='excluded from the workspace (avr-rust toolchain; built from its own dir)'
else
  insert_before "new-board(esp32/cortex-m): members" "  \"boards/$name\","
  membership='added as a [workspace] member'
fi

echo
echo "✓ created boards/$name  (crate: homelab-$name, kind: $kind)"
echo "  • $membership"
if [ "$kind" = "cortex-m" ]; then
  echo "  • EDIT for your exact MCU: memory.x, the embassy-stm32 chip feature in"
  echo "    Cargo.toml, and --chip in .cargo/config.toml"
fi
echo "  • register the physical unit in ../static/falcon.nix to flash via deploy-rs"
