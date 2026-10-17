{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  home = {
    config,
    lib,
    ...
  }: {
    # vdirsyncer asks before creating a collection that is missing on one side, which a launchd
    # agent cannot answer; the local directory exists first, so `discover` is silent.
    home.activation.vdirsyncerCollections = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run mkdir -p "${config.accounts.calendar.basePath}/org"
    '';
    accounts.calendar = {
      # Home-relative on purpose: HM prepends homeDirectory to non-absolute
      # paths ("~/..." would resolve to "$HOME/~/...").
      basePath = ".local/share/vdirsyncer/calendars";
      accounts.org = {
        # Not `primary`: khal names a `discover` group's calendars org1, org2, ..., so the account name
        # is not a valid `default_calendar`, and khal here only reads.
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
