# Off-site etcd snapshots via a systemd timer instead of rke2's built-in S3
# upload: `etcd-s3` in rke2's config only takes effect on an rke2-server restart,
# which is risky with etcd this fragile. `rke2 etcd-snapshot save --s3` asks the
# running server for a snapshot and uploads it, with no restart.
#
# Credentials are the existing VolSync B2 key, read at run time from a
# VolSync-managed secret in the cluster (no sops, no new secret). Snapshots land
# under etcd/ in the VolSync bucket; unencrypted, so the bucket must stay private.
# TODO once rke2 is restarted anyway: etcd-s3 + etcd-s3-config-secret, drop this.
{
  flake,
  config,
  pkgs,
  ...
}: let
  region = "us-west-004";
  bucket = "${builtins.replaceStrings ["."] ["-"] flake.config.canivete.meta.domain}--volsync";
  snapshot = pkgs.writeShellApplication {
    name = "etcd-snapshot-offsite";
    runtimeInputs = with pkgs; [kubectl coreutils gawk];
    text = ''
      export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
      names=$(kubectl get secret -A --no-headers \
        -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name)
      read -r ns name <<< "$(awk '$2 ~ /^volsync--/ {print; exit}' <<< "$names")"
      [ -n "''${name:-}" ] || { echo "no volsync-- secret to take B2 credentials from"; exit 1; }
      field() { kubectl -n "$ns" get secret "$name" -o go-template="{{.data.$1 | base64decode}}"; }
      AWS_ACCESS_KEY_ID=$(field AWS_ACCESS_KEY_ID)
      AWS_SECRET_ACCESS_KEY=$(field AWS_SECRET_ACCESS_KEY)
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
      # Per-node name: S3 retention prunes per name prefix, so servers don't evict each other.
      exec /run/current-system/sw/bin/rke2 etcd-snapshot save \
        --name "offsite-${config.networking.hostName}" \
        --snapshot-retention 3 \
        --s3 --s3-endpoint s3.${region}.backblazeb2.com --s3-region ${region} \
        --s3-bucket ${bucket} --s3-folder etcd --s3-retention 28 --s3-timeout 20m
    '';
  };
in {
  systemd.services.etcd-snapshot-offsite = {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${snapshot}/bin/etcd-snapshot-offsite";
      TimeoutStartSec = "30min";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };
  # Every 6h; the stable per-host delay spreads the three servers out so their
  # snapshots do not hit etcd together.
  systemd.timers.etcd-snapshot-offsite = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 00/6:00:00";
      RandomizedDelaySec = "1h";
      FixedRandomDelay = true;
      Persistent = true;
    };
  };
}
