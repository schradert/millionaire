{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  home = {...}: {
    # home-manager replaced programs.vdirsyncer.config with the shared
    # accounts.calendar tree (same move as khal — see modules/khal.nix, which
    # defines the org account's khal + local storage halves).
    accounts.calendar.accounts.org = {
      remote = {
        type = "caldav";
        url = "https://cal.${domain}/dav.php/calendars/admin/org/";
      };
      vdirsyncer = {
        enable = true;
        collections = ["from a" "from b"];
      };
    };
    programs.vdirsyncer = {
      enable = true;
      statusPath = "~/.local/share/vdirsyncer/status";
    };

    # systemd timer for Linux
    services.vdirsyncer = {
      enable = true;
      frequency = "*:0/5";
    };
  };

  darwin = {
    lib,
    pkgs,
    ...
  }: {
    launchd.agents.vdirsyncer = {
      config = {
        ProgramArguments = ["${lib.getExe pkgs.vdirsyncer}" "sync"];
        StartInterval = 300;
        RunAtLoad = true;
      };
    };
  };
}
