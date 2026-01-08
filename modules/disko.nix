{
  nixos = {flake, lib, ...}: {
    imports = [flake.inputs.disko.nixosModules.default];
    boot.supportedFilesystems = ["zfs"];
    services.zfs.autoScrub.enable = true;
    services.zfs.trim.enable = true;
    disko.devices.disk.root = {
      device = lib.mkDefault "/dev/sda";
      type = "disk";
      content.type = "gpt";
      content.partitions = {
        ESP = {
          type = "EF00";
          size = lib.mkDefault "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [
              "umask=0077"
              "nofail"
              "noatime"
              "noauto"
              "x-systemd.automount"
              "x-systemd.idle-timeout=1min"
            ];
          };
        };
        zfs = {
          size = "100%";
          content.type = "zfs";
          content.pool = "root";
        };
      };
    };
    disko.devices.zpool = {
      root = {
        type = "zpool";
        options.ashift = "12";
        options.autotrim = "on";
        rootFsOptions = {
          # https://jrs-s.net/2018/08/17/zfs-tuning-cheat-sheet/
          # https://rubenerd.com/forgetting-to-set-utf-normalisation-on-a-zfs-pool/
          acltype = "posixacl";
          atime = "off";
          canmount = "off";
          compression = "lz4";
          dnodesize = "auto";
          mountpoint = "none";
          normalization = "formD";
          xattr = "sa";
          "com.sun:auto-snapshot" = "true";
          # TODO do I need a postCreateHook to snapshot?
          # postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^${poolName}@blank$' || zfs snapshot ${poolName}@blank";
        };
        datasets = {
          # recomputed easily
          local = {
            type = "zfs_fs";
            options.mountpoint = "none";
          };
          "local/nix" = {
            type = "zfs_fs";
            options.reservation = "128M";
            options.mountpoint = "legacy";
            mountpoint = "/nix";
          };

          system = {
            type = "zfs_fs";
            options.mountpoint = "none";
          };
          "system/root" = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/";
          };
          "system/var" = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/var";
          };

          # user and services
          safe = {
            type = "zfs_fs";
            options.copies = "2";
            options.mountpoint = "none";
          };
          "safe/home" = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/home";
          };
          "safe/var/lib" = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/var/lib";
          };

          # temp
          temp = {
            type = "zfs_fs";
            options.sync = "disabled";
            options.mountpoint = "none";
          };
          "temp/tmp" = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/tmp";
          };
        };
      };
    };
  };
}
