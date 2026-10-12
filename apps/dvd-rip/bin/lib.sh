# shellcheck shell=bash
# Shared helpers for the dvd-* scripts. Sourced, not executed.

DVD_DEVICE="${DVD_DEVICE:-/dev/sr0}"
# Where every disc's working dir lives; override by exporting DVD_RIPS.
DVD_RIPS="${DVD_RIPS:-/data/dvd-rips}"

# Encoder knobs. NVENC on the RTX A2000 (Ampere) does H.264 and HEVC; it has
# no AV1 encoder (that needs Ada). H.264 direct-plays on every Jellyfin
# client; set ENCODER=nvenc_h265 for ~30% smaller files where clients cope.
ENCODER="${ENCODER:-nvenc_h264}"
ENCODER_PRESET="${ENCODER_PRESET:-slowest}"
QUALITY="${QUALITY:-19}"
PARALLEL="${PARALLEL:-4}"
# Keep each disc's decrypted master.iso (the full disc, menus and games
# included, for Kodi/VLC). KEEP_MASTERS=0 deletes it once encoded.
KEEP_MASTERS="${KEEP_MASTERS:-1}"

# Title classification thresholds (seconds).
STUB_MAX="${STUB_MAX:-5}"     # below: menu stubs/black frames, skipped
EXTRA_MIN="${EXTRA_MIN:-30}"  # below: bumpers/logos, encoded to short/ for review

# Service event log: one JSON line per state change in $DVD_EVENTS (for
# tooling/Claude to follow cheaply) plus a readable line on stderr (for the
# devenv up / process-compose log view).
DVD_EVENTS="${DVD_EVENTS:-$DVD_RIPS/events.jsonl}"
event() {
  local state="$1" level="$2" disc="$3" msg="$4"
  mkdir -p "$DVD_RIPS"
  jq -cn --arg ts "$(date -Is)" --arg level "$level" --arg state "$state" --arg disc "$disc" --arg msg "$msg" \
    '{ts: $ts, level: $level, state: $state, disc: $disc, msg: $msg}' >>"$DVD_EVENTS"
  printf '%s %-5s %-11s %s%s\n' "$(date +%T)" "$level" "$state" "${disc:+$disc: }" "$msg" >&2
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

require_drive() {
  local dev="$1"
  [ -b "$dev" ] || die "$dev is not a block device"
  [ -r "$dev" ] || die "no read access to $dev — run: dvd-access"
}

disc_label() {
  local label
  label=$(isoinfo -d -i "$1" 2>/dev/null | awk -F': ' '/Volume id/{print $2}' | xargs || true)
  echo "${label:-UNKNOWN}"
}

# Stable per-disc fingerprint (hash of VIDEO_TS.IFO): keeps two discs that
# share a generic label ("DVD_VIDEO", "DISC_1") from colliding, and lets the
# service recognise a disc it has already ripped. Empty if unreadable.
disc_id() {
  local id empty=e3b0c44298fc # sha256 of nothing = nothing read
  id=$(isoinfo -i "$1" -x '/VIDEO_TS/VIDEO_TS.IFO;1' 2>/dev/null | sha256sum | cut -c1-12)
  # UDF-only discs have no ISO9660 listing for isoinfo; fingerprint the title
  # structure via libdvdread instead (retrying while the drive spins up).
  for _ in 1 2 3; do
    [ "$id" = "$empty" ] || break
    id=$(lsdvd -x "$1" 2>/dev/null | grep -v '^Disc Title' | sha256sum | cut -c1-12)
    [ "$id" = "$empty" ] || break
    sleep 5
  done
  [ "$id" = "$empty" ] || echo "$id"
}

# Working dir of an already-known disc with this fingerprint, if any.
find_disc() {
  local f
  for f in "$DVD_RIPS"/*/.discid; do
    [ -f "$f" ] && [ "$(cat "$f")" = "$1" ] && { dirname "$f"; return; }
  done
  return 0
}

# Resolve (or allocate) the working dir for a disc: $DVD_RIPS/<LABEL>, or
# <LABEL>_<id> when that label is already taken by a different disc.
disc_dir() {
  local label="$1" id="$2" dir="$DVD_RIPS/$1"
  if [ -f "$dir/.discid" ] && [ "$(cat "$dir/.discid")" != "$id" ]; then
    dir="$DVD_RIPS/${label}_$id"
  fi
  mkdir -p "$dir/logs"
  echo "$id" >"$dir/.discid"
  echo "$dir"
}

# "Title Case" from a disc label: HOW_TO_TRAIN_YOUR_DRAGON -> How To Train Your
# Dragon; MONSTERS__INC_ -> Monsters Inc (no doubled/trailing spaces).
label_to_name() {
  tr '_' ' ' <<<"$1" | tr -s ' ' | sed -E 's/^ +//; s/ +$//' | tr '[:upper:]' '[:lower:]' | sed -E 's/(^| )([a-z])/\1\u\2/g'
}

# Resolve a disc argument: a bare name ("HOW_TO_TRAIN_YOUR_DRAGON") is looked
# up under $DVD_RIPS; anything else is taken as a path to a disc dir.
resolve_disc() {
  local arg="${1%/}"
  if [[ "$arg" != */* && -d "$DVD_RIPS/$arg" ]]; then
    echo "$DVD_RIPS/$arg"
  elif [ -d "$arg" ]; then
    echo "$arg"
  else
    die "no disc '$1' in $DVD_RIPS (have: $(find "$DVD_RIPS" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null))"
  fi
}

# True if the argument names a disc (bare name under $DVD_RIPS, or a dir).
is_disc() { [[ ( "$1" != */* && -d "$DVD_RIPS/${1%/}" ) || -d "$1" ]]; }

hms() { printf '%dh%02dm%02ds' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }
