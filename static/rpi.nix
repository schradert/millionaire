{
  config,
  flake,
  lib,
  ...
}: {
  imports = with flake.inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5; [
    base
    page-size-16k
    display-vc4
    bluetooth
  ];
  # Fleet default (modules/nixos.nix) is srvos systemd-boot; the RPi module
  # installs its own bootloader to /boot/firmware.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  system.nixos.tags = let
    cfg = config.boot.loader.raspberry-pi;
  in [
    "raspberry-pi-${cfg.variant}"
    cfg.bootloader
    config.boot.kernelPackages.kernel.version
  ];
  # https://www.raspberrypi.com/documentation/computers/config_txt.html
  hardware.raspberry-pi.config.all = {
    options.enable_uart = {
      enable = true;
      value = true;
    };
    options.uart_2ndstage = {
      enable = true;
      value = true;
    };
    base-dt-params.pciex1 = {
      enable = true;
      value = "on";
    };
    base-dt-params.pciex1_gen = {
      enable = true;
      value = "3";
    };
  };
  disko.devices.disk.root.content.partitions = {
    FIRMWARE = {
      priority = 1;
      label = "FIRMWARE";
      type = "0700";
      attributes = [0];
      size = "1024M";
      content = {
        type = "filesystem";
        format = "vfat";
        mountpoint = "/boot/firmware";
        mountOptions = [
          "nofail"
          "noatime"
          "noauto"
          "x-systemd.automount"
          "x-systemd.idle-timeout=1min"
        ];
      };
    };
    ESP = {
      label = "ESP";
      # BIOS bootable, for U-Boot to find extlinux config
      attributes = [2];
      size = "1024M";
    };
  };
}
