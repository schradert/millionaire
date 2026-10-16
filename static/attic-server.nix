# Attic binary cache server; every node and Mac substitutes from http://chinchilla:8199/main
# (static/k8s-node.nix). The cache is rebuildable, so it gets its own dataset under `local`:
# quota-capped (the pool is shared with rke2 and containerd), no snapshots, copies=1.
{
  config,
  lib,
  pkgs,
  ...
}: let
  dataset = "root/local/attic";
  dir = "/var/lib/private/atticd"; # StateDirectory of the DynamicUser service
  zfs = lib.getExe' config.boot.zfs.package "zfs";
in {
  services.atticd = {
    enable = true;
    environmentFile = config.sops.secrets.attic-server-key.path;
    settings = {
      listen = "[::]:8199";
      garbage-collection.default-retention-period = "30 days";
    };
  };
  sops.secrets.attic-server-key.key = "attic/server-key";
  networking.firewall.allowedTCPPorts = [8199];

  systemd.services.atticd-dataset = {
    path = [pkgs.util-linux];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${zfs} list -H -o name ${dataset} >/dev/null 2>&1 \
        || ${zfs} create -o mountpoint=${dir} -o com.sun:auto-snapshot=false ${dataset}
      ${zfs} set quota=50G ${dataset}
      mountpoint -q ${dir} || ${zfs} mount ${dataset}
    '';
  };
  systemd.services.atticd.requires = ["atticd-dataset.service"];
  systemd.services.atticd.after = ["atticd-dataset.service"];
}
