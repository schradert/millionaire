# DVD ripping service (apps/dvd-rip): dvd-watch backs up each inserted disc to
# $DVD_RIPS/<LABEL>/master.iso and ejects it; dvd-worker encodes it into
# library/. Events: $DVD_RIPS/events.jsonl and the units' journals.
# `touch $DVD_RIPS/.pause` (or `systemctl stop dvd-watch`) leaves the drive alone.
{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.dvd-rip;
    # Stock nixpkgs (cached): the host's cudaSupport would rebuild HandBrake and ffmpeg
    # from source, and NVENC needs no CUDA build (HandBrake dlopens the driver).
    dvdPkgs = import pkgs.path {
      inherit (pkgs.stdenv.hostPlatform) system;
      config.allowUnfreePredicate = p: lib.getName p == "makemkv";
    };
    package = dvdPkgs.callPackage ../apps/dvd-rip/package.nix {};
  in {
    options.services.dvd-rip = {
      enable = lib.mkEnableOption "the DVD ripping service";
      user = lib.mkOption {
        type = lib.types.str;
        default = "tristan";
        description = "Runs the service and owns the rips (the dvd-* commands are run by hand as this user too).";
      };
      uid = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Pins the user's uid, so a reinstall cannot renumber it away from the rips it owns (its group is `users`, gid 100).";
      };
      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/sr0";
      };
      rips = lib.mkOption {
        type = lib.types.str;
        default = "/data/dvd-rips";
      };
    };
    config = lib.mkIf cfg.enable {
      environment.systemPackages = [package];
      environment.variables.DVD_RIPS = cfg.rips;
      # MakeMKV reads the drive through its SCSI-generic node; udev gives both to `cdrom`.
      boot.kernelModules = ["sg"];
      users.users.${cfg.user} = {
        extraGroups = ["cdrom"];
        uid = lib.mkIf (cfg.uid != null) cfg.uid;
      };
      systemd.services = lib.genAttrs ["dvd-watch" "dvd-worker"] (name: {
        description = "DVD ripping: ${name}";
        wantedBy = ["multi-user.target"];
        unitConfig.RequiresMountsFor = cfg.rips;
        environment = {
          DVD_RIPS = cfg.rips;
          DVD_DEVICE = cfg.device;
        };
        serviceConfig = {
          User = cfg.user;
          SupplementaryGroups = ["cdrom" "video" "render"];
          # Rips written under an earlier uid (a reinstall renumbers the user): take them over once.
          ExecStartPre = "+${pkgs.writeShellScript "dvd-rips-owner" ''
            [ "$(${pkgs.coreutils}/bin/stat -c %U ${cfg.rips})" = ${cfg.user} ] ||
              ${pkgs.coreutils}/bin/chown -R ${cfg.user}: ${cfg.rips}
          ''}";
          ExecStart = lib.getExe' package name;
          Restart = "always";
          RestartSec = 10;
        };
      });
    };
  };
}
