{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  home = {...}: {
    accounts.calendar = {
      # Home-relative on purpose: HM prepends homeDirectory to non-absolute
      # paths ("~/..." would resolve to "$HOME/~/...").
      basePath = ".local/share/vdirsyncer/calendars";
      accounts.org = {
        primary = true;
        local = {
          type = "filesystem";
          path = "~/.local/share/vdirsyncer/calendars";
          fileExt = ".ics";
        };
        remote = {
          type = "caldav";
          url = "https://cal.${domain}/dav.php/calendars/admin/org/";
          # Baïkal's DAV user (nixidy/apps/home/baikal.nix generatedSecrets)
          userName = "admin";
          passwordCommand = ["bws-get" "baikal/admin-password"];
        };
        khal = {
          enable = true;
          type = "discover";
          glob = "*";
          color = "light magenta";
        };
        vdirsyncer = {
          enable = true;
          collections = ["from a" "from b"];
          auth = "digest";
        };
      };
    };
  };
}
