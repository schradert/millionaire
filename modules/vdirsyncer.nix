{
  home = {...}: {
    programs.vdirsyncer.enable = true;

    # systemd timer for Linux
    services.vdirsyncer = {
      enable = true;
      frequency = "*:0/5";
    };
  };

  # The agent discovers the collections once (modules/calendar.nix pre-creates the local ones, so
  # discovery never asks a question) and then syncs every five minutes. launchd's PATH has neither
  # the profile nor `bws-get`, which the Baïkal password comes from.
  darwin = {
    flake,
    lib,
    pkgs,
    ...
  }: let
    inherit (flake.config.canivete.meta.people) me;
    vdirsyncer = lib.getExe pkgs.vdirsyncer;
    status = "$HOME/.local/share/vdirsyncer/status";
    # The local copy only mirrors Baïkal, which org-bridge rebuilds from the org files, so when the
    # calendar has become empty (the last event deleted) vdirsyncer's safety stop is wrong to
    # block: it refuses until forced.
    sync = "${vdirsyncer} sync || ${vdirsyncer} sync --force-delete";
  in {
    launchd.agents.vdirsyncer = {
      serviceConfig = {
        ProgramArguments = ["/bin/sh" "-c" "[ -d ${status} ] || ${vdirsyncer} discover; ${sync}"];
        StartInterval = 300;
        RunAtLoad = true;
        EnvironmentVariables.PATH = lib.concatStringsSep ":" ["/Users/${me}/.nix-profile/bin" "/etc/profiles/per-user/${me}/bin" "/usr/bin" "/bin"];
      };
    };
  };
}
