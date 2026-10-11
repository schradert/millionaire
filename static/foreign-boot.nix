# Hosts whose platform owns boot and storage (mobile-nixos, NixOS-WSL): drop the
# fleet's disko ZFS layout, ZFS kernel and systemd-boot (modules/{disko,nixos}.nix).
{
  flake,
  lib,
  ...
}: {
  disabledModules = ["${flake.inputs.srvos}/nixos/mixins/latest-zfs-kernel.nix"];
  disko.enableConfig = false;
  boot.supportedFilesystems = lib.mkForce [];
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  services.zfs.autoScrub.enable = lib.mkForce false;
  services.zfs.trim.enable = lib.mkForce false;
}
