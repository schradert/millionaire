{
  home = {...}: {
    # home-manager moved per-calendar khal config from programs.khal.accounts
    # to the shared accounts.calendar tree; programs.khal keeps only
    # enable/locale/settings.
    accounts.calendar.accounts.org = {
      khal = {
        enable = true;
        type = "discover";
        glob = "*";
        color = "light magenta";
      };
      local = {
        type = "filesystem";
        path = "~/.local/share/vdirsyncer/calendars";
        fileExt = ".ics";
      };
    };
    programs.khal = {
      enable = true;
      locale = {
        timeformat = "%H:%M";
        dateformat = "%Y-%m-%d";
        default_timezone = "America/Los_Angeles";
      };
      settings = {
        default.default_calendar = "org";
        view.theme = "dark";
      };
    };
  };
}
