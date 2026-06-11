# Minimal golden image for Hetzner Cloud x86 VMs.
#
# Hetzner x86 servers boot legacy BIOS (SeaBIOS) — no UEFI — so this image
# uses GRUB with MBR boot code instead of the systemd-boot + ESP layout the
# bare-metal nodes use (modules/disko.nix). That mismatch is why
# nixos-anywhere installs never came back up: the installed disk had no BIOS
# boot path at all.
#
# The image is just enough to boot and accept root SSH; the real node config
# lands afterwards via deploy-rs / nixos-rebuild.
#
# Build (x86_64-linux only):
#   nix build .#nixosConfigurations.hetzner-image.config.system.build.hetznerImage
# Upload:
#   hcloud-upload-image upload --architecture x86 --compression xz --image-path <nixos.img.xz>
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}: {
  imports = ["${modulesPath}/profiles/qemu-guest.nix"];

  system.stateVersion = "26.05";

  # GRUB writes MBR boot code into the image inside the build VM, where the
  # disk is virtio-blk (/dev/vda). The full node config deployed later must
  # set boot.loader.grub.device to the runtime disk (/dev/sda) instead.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";
  boot.loader.timeout = 1;
  boot.growPartition = true;
  # Serial console so the Hetzner web console shows boot logs
  boot.kernelParams = ["console=tty1" "console=ttyS0,115200"];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  networking.useDHCP = true;

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFBq/GWgq0+wAbRS53AqDdgXhyqpQtvcwlsPEguTPzL9 tristan@millionaire"
  ];

  system.build.hetznerImage = import "${modulesPath}/../lib/make-disk-image.nix" {
    inherit config lib pkgs;
    format = "raw";
    partitionTableType = "legacy";
    diskSize = "auto";
    additionalSpace = "2G";
  };
}
