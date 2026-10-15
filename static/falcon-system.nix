# falcon (Dell Precision 7820): NixOS desktop and RKE2 agent (k8s-node + desktop-node:
# the NVIDIA GPU serves the cluster's gpu-operator workloads), MCU flash host
# (./falcon.nix profiles) and the fleet's biggest builder (static/builders.nix).
# Standard layout: docs/node-standard.md.
# Unported: vscode + Continue extension (old/infra/nodes/nixos/default.nix).
{
  config,
  flake,
  lib,
  ...
}: let
  zfsBin = "${config.boot.zfs.package}/bin/zfs";
  # data/<name> -> /data/<name>, with the properties it is created with
  dataDatasets = {
    dvd-rips = ["recordsize=1M"];
    media = ["recordsize=1M"];
    scratch = ["sync=disabled" "com.sun:auto-snapshot=false"];
    backup = [];
  };
in {
  # A node joins the cluster tailnet (k8s-node), so tailnet-personal.nix is not imported.
  imports = [./k8s-node.nix ./desktop-node.nix ./zfs-legacy.nix flake.inputs.srvos.nixosModules.desktop];
  profiles = {
    client.enable = true;
    desktop.hyprland.enable = true;
    gaming.enable = true;
    nvidia.enable = true;
    workstation.enable = true;
  };
  workstationKeys.enable = true;
  apiKeys.enable = true; # falcon is a recipient of personal.yaml (.sops.yaml)
  # Installed by the old dotfiles repo
  system.stateVersion = "25.11";
  home-manager.sharedModules = [{home.stateVersion = "25.11";}];
  # node hostname is the LAN IP (ssh target)
  networking.hostName = lib.mkForce "falcon";
  networking.hostId = "fa7c0969";

  disko.devices.disk.root.device = "/dev/disk/by-id/nvme-PC801_NVMe_SK_hynix_1TB__SIABN06591CB93G1B";
  # The live install is the flat root/{root,home,tmp} layout. Unset this at the
  # deliberate reinstall onto the standard layout (docs/node-standard.md).
  desktopNode.lanLink.Driver = "e1000e"; # onboard NIC; the r8152 USB dongle keeps its name

  # The `data` pool (3.6T Toshiba disk, 1.47T of DVD rips) is deliberately NOT
  # in disko: disko rewrites the GPT of every disk it declares, so listing it
  # would let a reinstall format the data. It is imported by name and mounted
  # as plain fileSystems; only `disk.root` is ever partitioned.
  boot.zfs.extraPools = ["data"];
  fileSystems = let
    # zfsutil: mount by the dataset's own mountpoint property. nofail: a
    # missing or dead data disk must not keep a cluster node from booting.
    zfs = dataset: {
      device = dataset;
      fsType = "zfs";
      options = ["zfsutil" "nofail"];
    };
  in
    {"/data" = zfs "data/root";} // lib.mapAttrs' (n: _: lib.nameValuePair "/data/${n}" (zfs "data/${n}")) dataDatasets;
  # Only dvd-rips exists on the live pool (plus the empty data/root that /data
  # mounts); creating the rest is idempotent and happens right after the import,
  # before anything mounts. -u: created unmounted, so nothing lands under a
  # still-unmounted /data. Existing datasets are never touched.
  systemd.services.zfs-import-data.postStart = lib.concatStrings (lib.mapAttrsToList (n: opts: ''
      ${zfsBin} list -H -o name data/${n} >/dev/null 2>&1 \
        || ${zfsBin} create -u -o mountpoint=/data/${n} ${lib.concatMapStringsSep " " (o: "-o ${o}") opts} data/${n}
    '')
    dataDatasets);

  boot.binfmt.emulatedSystems = ["aarch64-linux"];
  boot.initrd.availableKernelModules = ["sr_mod"];
  # NIC keeps getting stuck in ULP mode, dropping the network
  boot.extraModprobeConfig = "options e1000e EEE=0";
  # ACPI DSDT bug for Super IO + UART: keep the kernel off the 8250 ports
  boot.kernelParams = ["8250.nr_uarts=0"];

  # Fleet builder (static/builders.nix): the dev host and every cluster node
  # (by ssh host key) are authorized in static/builder.nix; no caps here, the
  # idle scheduling there keeps the desktop responsive.
}
