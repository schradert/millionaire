{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  home = {
    lib,
    pkgs,
    ...
  }: {
    programs.vdirsyncer = {
      enable = true;
      config = {
        general.status_path = "~/.local/share/vdirsyncer/status";
        "pair org_calendar" = {
          a = "org_calendar_local";
          b = "org_calendar_remote";
          collections = ["from a" "from b"];
        };
        "storage org_calendar_local" = {
          type = "filesystem";
          path = "~/.local/share/vdirsyncer/calendars";
          fileext = ".ics";
        };
        "storage org_calendar_remote" = {
          type = "caldav";
          url = "https://cal.${domain}/dav.php/calendars/admin/org/";
        };
      };
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
