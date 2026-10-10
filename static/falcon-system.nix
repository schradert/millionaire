# falcon (Dell Precision 7820): NixOS desktop, MCU flash host (./falcon.nix
# profiles) and the Mac's preferred remote builder.
# Unported: vscode + Continue extension (old/infra/nodes/nixos/default.nix).
{
  flake,
  lib,
  ...
}: {
  imports = [./tailnet-personal.nix ./zfs-legacy.nix] ++ (with flake.inputs.srvos.nixosModules; [desktop roles-nix-remote-builder]);
  profiles = {
    client.enable = true;
    gaming.enable = true;
    nvidia.enable = true;
    workstation.enable = true;
  };
  # Installed by the old dotfiles repo
  system.stateVersion = "25.11";
  home-manager.sharedModules = [{home.stateVersion = "25.11";}];
  # node hostname is the LAN IP (ssh target)
  networking.hostName = lib.mkForce "falcon";
  networking.hostId = "fa7c0969";

  disko.devices.disk.root.device = "/dev/disk/by-id/nvme-PC801_NVMe_SK_hynix_1TB__SIABN06591CB93G1B";
  disko.devices.disk.data = {
    type = "disk";
    device = "/dev/disk/by-id/ata-TOSHIBA_MG08ADA400NY_X1Q0A2MPFYXG";
    content.type = "gpt";
    content.partitions.zfs = {
      size = "100%";
      content.type = "zfs";
      content.pool = "data";
    };
  };
  disko.devices.zpool.data = {
    type = "zpool";
    options.ashift = "12";
    rootFsOptions = {
      mountpoint = "none";
      compression = "lz4";
      acltype = "posixacl";
      xattr = "sa";
      "com.sun:auto-snapshot" = "true";
    };
    datasets.root = {
      type = "zfs_fs";
      mountpoint = "/data";
    };
  };

  boot.binfmt.emulatedSystems = ["aarch64-linux"];
  boot.initrd.availableKernelModules = ["sr_mod"];
  # NIC keeps getting stuck in ULP mode, dropping the network
  boot.extraModprobeConfig = "options e1000e EEE=0";
  # ACPI DSDT bug for Super IO + UART: keep the kernel off the 8250 ports
  boot.kernelParams = ["8250.nr_uarts=0"];

  roles.nix-remote-builder.schedulerPublicKeys = [flake.config.canivete.meta.people.my.profiles.personal.sshPubKey];
}
