# Nightly off-host backup of headscale's state (node registrations in db.sqlite, the noise and DERP private
# keys): a consistent sqlite `.backup`, tarred, encrypted to the offline age key `age.bws-backup` (private half
# in secrets/sops/personal.yaml, same key as the Bitwarden backup, apps/bws-backup) and uploaded to the VolSync
# B2 bucket under headscale-backup/ (newest 30 kept). Restore test: the devshell script `headscale-backup-restore-test`.
# Credentials: the VolSync bucket key (BWS `backblaze/bucket/*`) that pulumi copies into secrets/sops/default.yaml
# (`headscale_backup_b2_sops_write`). The S3 API rejects the B2 master key in sops (`b2.id`: "Malformed Access Key Id").
# Everything below is off until those keys are in the file (sops-nix fails the whole host build on a missing key), so
# this is a no-op until pulumi has written them and the file is committed.
# TODO narrow it to a key restricted to the headscale-backup/ prefix (`b2 key create --name-prefix`).
{
  config,
  flake,
  lib,
  pkgs,
  ...
}: let
  # Key names in a sops file are cleartext.
  keyWritten = lib.hasInfix "\nbackblaze:\n    bucket:\n        application_key_id:" (builtins.readFile ../secrets/sops/default.yaml);
  bucket = "${builtins.replaceStrings ["."] ["-"] flake.config.canivete.meta.domain}--volsync";
  recipient = "age17nlj7qd3znnvf8njwgl56ms2vacp2uxgglzzap6j6vw9c5w9yprqed2r39";
  backup = pkgs.writeShellApplication {
    name = "headscale-backup";
    runtimeInputs = with pkgs; [age coreutils gnutar gzip rclone sqlite];
    text = ''
      state=''${STATE_DIR:-/var/lib/headscale}
      export RCLONE_S3_PROVIDER=Other RCLONE_S3_NO_CHECK_BUCKET=true
      RCLONE_S3_ENDPOINT=''${B2_ENDPOINT:-https://s3.us-west-004.backblazeb2.com}
      export RCLONE_S3_ENDPOINT
      dest=":s3:${bucket}/headscale-backup"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      : > "$work/rclone.conf"
      export RCLONE_CONFIG="$work/rclone.conf"
      name="headscale-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"

      mkdir "$work/state"
      sqlite3 -cmd ".timeout 10000" "$state/db.sqlite" ".backup '$work/state/db.sqlite'"
      [ "$(sqlite3 "$work/state/db.sqlite" "PRAGMA integrity_check")" = ok ] || { echo "backup failed the integrity check" >&2; exit 1; }
      echo "nodes: $(sqlite3 "$work/state/db.sqlite" "SELECT count(*) FROM nodes WHERE deleted_at IS NULL")"
      cp "$state/noise_private.key" "$state/derp_server_private.key" "$work/state/"
      tar -C "$work/state" -czf - . | age -r ${recipient} -o "$work/$name"
      rm -r "$work/state"

      rclone copyto "$work/$name" "$dest/$name"
      size=$(stat -c %s "$work/$name")
      [ "$(rclone lsf --files-only --format s "$dest/$name")" = "$size" ] || { echo "uploaded $name has the wrong size" >&2; exit 1; }
      echo "uploaded headscale-backup/$name ($size bytes)"

      # Names sort by time; keep the newest 30.
      rclone lsf --files-only "$dest" | sort | head -n -30 | while read -r old; do
        rclone deletefile "$dest/$old"
        echo "deleted headscale-backup/$old"
      done
    '';
  };
in {
  config = lib.mkIf keyWritten {
    sops.secrets = {
      b2-key-id.key = "backblaze/bucket/application_key_id";
      b2-key.key = "backblaze/bucket/application_key";
    };
    sops.templates."headscale-backup.env" = {
      owner = "headscale";
      content = ''
        RCLONE_S3_ACCESS_KEY_ID=${config.sops.placeholder.b2-key-id}
        RCLONE_S3_SECRET_ACCESS_KEY=${config.sops.placeholder.b2-key}
      '';
    };

    systemd.services.headscale-backup = {
      description = "Encrypted off-host backup of headscale state";
      onFailure = ["headscale-backup-failed.service"];
      serviceConfig = {
        Type = "oneshot";
        User = "headscale";
        EnvironmentFile = config.sops.templates."headscale-backup.env".path;
        ExecStart = lib.getExe backup;
        TimeoutStartSec = "15min";
        Nice = 10;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        # sqlite needs the WAL and shared-memory files next to the database.
        ReadWritePaths = ["/var/lib/headscale"];
      };
    };
    systemd.timers.headscale-backup = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* 02:30:00";
        RandomizedDelaySec = "20m";
        Persistent = true;
      };
    };

    # hyena's own ntfy (tailnet-only, no auth), the topic Gatus alerts to.
    systemd.services.headscale-backup-failed = {
      description = "Alert that the headscale backup failed";
      serviceConfig.Type = "oneshot";
      path = [pkgs.curl];
      script = ''
        curl -fsS -H "Title: headscale backup failed" -H "Priority: 4" -H "Tags: warning" \
          -d "headscale-backup.service failed on hyena: journalctl -u headscale-backup" http://127.0.0.1:2586/alerts
      '';
    };
  };
}
