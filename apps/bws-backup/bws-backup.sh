#!/usr/bin/env bash
# Weekly Bitwarden Secrets Manager backup. Run by the bws-backup CronJob (nixidy/system/security/bws-backup.nix):
# `bws secret list` (keys and values of everything the machine account can see), encrypted to an age
# public key whose private half is NOT in the cluster or in Bitwarden (secrets/sops/personal.yaml,
# `age.bws-backup`), uploaded to the VolSync B2 bucket under $PREFIX/, newest $KEEP kept.
# Restore test (needs the private key): the devshell script `bws-backup-restore-test`.
set -euo pipefail

: "${BWS_ACCESS_TOKEN:?}" "${AGE_RECIPIENT:?}" "${BUCKET:?}" "${B2_ENDPOINT:?}" "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}"
PREFIX=${PREFIX:-bws-backup}
KEEP=${KEEP:-12}
REQUIRE_KEY=${REQUIRE_KEY:-volsync/restic/password}

export RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT="$B2_ENDPOINT" RCLONE_S3_NO_CHECK_BUCKET=true
export RCLONE_S3_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" RCLONE_S3_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
dest=":s3:$BUCKET/$PREFIX"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: > "$work/rclone.conf"
export RCLONE_CONFIG="$work/rclone.conf"
name="$(date -u +%Y-%m-%dT%H%M%SZ).json.age"

bws secret list -o json > "$work/secrets.json"
# An empty or truncated listing must fail the job, not overwrite good history with a useless object.
jq -e --arg k "$REQUIRE_KEY" 'type == "array" and any(.[]; .key == $k)' "$work/secrets.json" > /dev/null \
  || { echo "listing has no '$REQUIRE_KEY' entry: not backing up" >&2; exit 1; }
echo "listed $(jq length "$work/secrets.json") secrets"
age -r "$AGE_RECIPIENT" -o "$work/$name" "$work/secrets.json"
rm "$work/secrets.json"

rclone copyto "$work/$name" "$dest/$name"
size=$(stat -c %s "$work/$name")
[ "$(rclone lsf --files-only --format s "$dest/$name")" = "$size" ] || { echo "uploaded $name has the wrong size" >&2; exit 1; }
echo "uploaded $PREFIX/$name ($size bytes)"

# Names sort by time; keep the newest $KEEP.
rclone lsf --files-only "$dest" | sort | head -n -"$KEEP" | while read -r old; do
  rclone deletefile "$dest/$old"
  echo "deleted $PREFIX/$old"
done
