# bonobo converges the phones that have a management channel (docs/android-fleet.md, "Decision"): a timer per device
# runs the same script as `android <device> reconcile` (static/android-adb.sh behind static/android-reconcile.sh) with
# bonobo's own channel key, installs and updates the catalog's apps silently through Shizuku, and posts the outcome to
# the device's ntfy topic when it changed. A phone that is off, off the tailnet or without Shizuku is not an error of
# the unit: its apps stay `pending` and the next run tries again. Needs the channel key (`pulumi up` writes it to
# sops; the file check below keeps sops-nix from failing a build before that) and, for the ntfy report, the publisher token.
{
  config,
  flake,
  lib,
  pkgs,
  ...
}: let
  inherit (flake.config.canivete.meta.people) me;
  user = config.users.users.${me};
  sops' = builtins.readFile ../secrets/sops/default.yaml;
  sshKeyWritten = lib.hasInfix "\n    ssh-key: ENC" sops';
  ntfyWritten = lib.hasInfix "\nntfy:\n    " sops';
  devices = flake.config.android.reconcile;
  runner = name: dev:
    pkgs.writeShellApplication {
      name = "android-reconcile-${name}";
      runtimeInputs = with pkgs; [bash android-tools nmap curl jq unzip openssh coreutils gnused gnugrep gawk findutils config.services.tailscale.package];
      text = ''
        want=$(cat ${pkgs.writeText "android-${name}.json" (builtins.toJSON dev)})
        {
          printf 'dev=%q\nchan_port=%q\nchan_wakelock=%q\nact=reconcile\nwant=%q\nntfy=%q\n' \
            ${name} ${toString dev.channel.port} ${lib.boolToString dev.channel.wakeLock} "$want" "https://${dev.ntfyHost}/${dev.topic}"
          ${lib.optionalString ntfyWritten ''printf 'ntfy_token_file=%q\n' ${config.sops.secrets.android-ntfy-token.path}''}
          cat ${./android-reconcile.sh} ${./android-adb.sh}
        } | bash -s -- ${dev.hostname}
      '';
    };
in {
  config = lib.mkIf sshKeyWritten {
    sops.secrets.android-ntfy-token = lib.mkIf ntfyWritten {
      key = "ntfy/publisher/token";
      owner = me;
      mode = "0400";
    };
    systemd.services = lib.mapAttrs' (name: dev:
      lib.nameValuePair "android-reconcile-${name}" {
        description = "install and update the apps of ${name} over its management channel";
        after = ["tailscaled.service" "network-online.target"];
        wants = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          User = me;
          ExecStart = lib.getExe (runner name dev);
          # a phone that is off, away or without Shizuku is pending, not a failed unit (3: no channel or adb, 4: pairing, 5: pending, 6: Shizuku down)
          SuccessExitStatus = "3 4 5 6";
          TimeoutStartSec = "3h";
          # bonobo is an etcd member: stay out of the way
          Nice = 19;
          IOSchedulingClass = "idle";
          MemoryMax = "1G";
          Environment = ["HOME=${user.home}"];
        };
      })
    devices;
    systemd.timers = lib.mapAttrs' (name: dev:
      lib.nameValuePair "android-reconcile-${name}" {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = dev.channel.interval;
          RandomizedDelaySec = "10m";
          Persistent = true;
        };
      })
    devices;
  };
}
