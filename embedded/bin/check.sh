#!/usr/bin/env bash
# Compile + clippy every board for its own target — the embedded "CI".
#
# Why on falcon: the boards target Xtensa / RISC-V / Cortex-M / AVR and the
# esp boards need `build-std`, which only compiles on falcon's Linux esp-rs
# toolchain (not on macOS — see ../TARGETS.md). So `check` syncs the source to
# falcon and runs `cargo clippy` per board there, each in its own dir so it
# picks up that board's target + .cargo/config. Reports pass/fail per board and
# exits non-zero if any board fails — suitable for a pre-push gate or CI.
#
# Usage: check [board ...]   (default: all boards)
set -uo pipefail

ROOT="${DEVENV_ROOT:-$PWD}"
REPO="$(cd "$ROOT/.." && pwd)"
BASTION="tristan@192.184.168.248"
FALCON="tristan@192.168.50.215"
REMOTE_DIR="Projects/millionaire/embedded"

ALL_BOARDS=(esp32-c3 esp32-s3 stm32-nucleo teensy-4.1 arduino-uno-r3)
BOARDS=("$@"); [ ${#BOARDS[@]} -eq 0 ] && BOARDS=("${ALL_BOARDS[@]}")

echo "[check] syncing source to falcon..."
rsync -az --delete \
  --exclude 'target/' --exclude '.git/' --exclude '.direnv/' --exclude '.devenv/' \
  -e "ssh -J $BASTION" \
  "$ROOT/" "$FALCON:$REMOTE_DIR/" >/dev/null || { echo "[check] rsync failed" >&2; exit 1; }

fail=0
for b in "${BOARDS[@]}"; do
  printf '[check] %-16s ' "$b ..."
  # clippy = type-check + lints without a final link, in the board's own dir so
  # its .cargo/config (target + build-std) applies. Deny warnings to make the
  # gate meaningful.
  if ssh -J "$BASTION" "$FALCON" \
       "cd ~/$REMOTE_DIR/boards/$b && direnv exec . cargo clippy --release -- -D warnings" \
       >"/tmp/check-$b.log" 2>&1; then
    echo "PASS"
  else
    echo "FAIL (see below)"
    fail=1
    tail -25 "/tmp/check-$b.log" | sed 's/^/    /'
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "[check] all ${#BOARDS[@]} board(s) passed ✓"
else
  echo "[check] FAILURES above ✗" >&2
fi
exit "$fail"
