{
  home = {...}: {
    # Sync, then show the agenda. The launchd agent (modules/vdirsyncer.nix) cannot reach a LAN-only
    # Baïkal from a Mac that is not on the headscale tailnet (macOS Local Network privacy refuses
    # background processes: "No route to host"); a terminal can.
    home.shellAliases.cal = "(vdirsyncer sync || vdirsyncer sync --force-delete) && khal calendar";
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
