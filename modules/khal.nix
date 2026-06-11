{
  home = {...}: {
    programs.khal = {
      enable = true;
      locale = {
        timeformat = "%H:%M";
        dateformat = "%Y-%m-%d";
        default_timezone = "America/Los_Angeles";
      };
      settings.view.theme = "dark";
    };
  };
}
