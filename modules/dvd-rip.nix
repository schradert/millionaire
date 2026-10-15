# DVD ripping on a host with an optical drive, in one of two modes:
#
# - "local" (apps/dvd-rip): the dvd-watch unit backs up each inserted disc to
#   $DVD_RIPS/<LABEL>/master.iso and ejects it; dvd-worker encodes it into library/. Events:
#   $DVD_RIPS/events.jsonl and the units' journals. `touch $DVD_RIPS/.pause` (or
#   `systemctl stop dvd-watch`) leaves the drive alone.
# - "cluster" (apps/dvdrip, docs/dvd-rip.md): no units; a udev rule writes the Node Feature
#   Discovery feature dvd.trdos.me/drive=true while the host has an optical drive, and the dvdrip
#   agent DaemonSet runs on the nodes carrying that label. `touch /var/lib/dvd-rip/.pause` (or
#   `kubectl patch drive <node>-sr0 --type merge -p '{"spec":{"enabled":false}}'`) leaves the
#   drives alone.
#
# The dvd-* commands are installed in both modes, for the rips already under $DVD_RIPS.
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
    # NFD's local feature source (the worker mounts this dir from the host).
    features = "/etc/kubernetes/node-feature-discovery/features.d";
    label = pkgs.writeShellScript "dvd-drive-label" ''
      if ls /sys/class/block/sr* >/dev/null 2>&1; then
        ${pkgs.coreutils}/bin/mkdir -p ${features}
        echo dvd.trdos.me/drive=true > ${features}/dvd
      else
        ${pkgs.coreutils}/bin/rm -f ${features}/dvd
      fi
    '';
  in {
    options.services.dvd-rip = {
      enable = lib.mkEnableOption "DVD ripping on this host";
      mode = lib.mkOption {
        type = lib.types.enum ["local" "cluster"];
        default = "local";
        description = "local: the dvd-watch/dvd-worker units; cluster: label the node for the dvdrip agent.";
      };
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
    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        environment.systemPackages = [package];
        environment.variables.DVD_RIPS = cfg.rips;
        # MakeMKV reads the drive through its SCSI-generic node; udev gives both to `cdrom`.
        boot.kernelModules = ["sg"];
        users.users.${cfg.user} = {
          extraGroups = ["cdrom"];
          uid = lib.mkIf (cfg.uid != null) cfg.uid;
        };
      }
      (lib.mkIf (cfg.mode == "local") {
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
      })
      (lib.mkIf (cfg.mode == "cluster") {
        # Drives come and go (USB): relabel on every optical block device change, and at boot.
        services.udev.extraRules = ''
          SUBSYSTEM=="block", KERNEL=="sr[0-9]*", ACTION=="add|remove", RUN+="${label}"
        '';
        systemd.services.dvd-drive-label = {
          description = "Label this node for the dvdrip agent if it has an optical drive";
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = label;
          };
        };
        systemd.tmpfiles.rules = ["d /var/lib/dvd-rip 0755 root root -"];
      })
    ]);
  };
}
