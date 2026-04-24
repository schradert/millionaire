{
  home = {config, ...}: {
    programs.khal = {
      enable = true;
      locale = {
        timeformat = "%H:%M";
        dateformat = "%Y-%m-%d";
        default_timezone = "America/Los_Angeles";
      };
      accounts.org = {
        khal = {
          type = "discover";
          glob = "*";
          color = "light magenta";
        };
        local = {
          type = "filesystem";
          path = "~/.local/share/vdirsyncer/calendars";
          fileext = ".ics";
        };
      };
      settings = {
        default.default_calendar = "org";
        view.theme = "dark";
      };
    };
  };
}
