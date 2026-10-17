{config, ...}: let
  inherit (config.canivete.meta) domain;
  inherit (config.canivete.meta.people) me;
in {
  # Baïkal's DAV password, copied once from Bitwarden `baikal/admin-password` into personal.yaml
  # (`baikal/admin-password`) and decrypted like modules/api-keys.nix (0400, owned by the user), so
  # the launchd agent needs neither a repo checkout nor `bws-get`.
  system = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.apiKeys.enable {
      sops.secrets.baikal-admin-password = {
        key = "baikal/admin-password";
        sopsFile = builtins.path {
          path = ../secrets/sops/personal.yaml;
          name = "sops-personal.yaml";
        };
        owner = me;
        mode = "0400";
      };
    };
  };

  home = {
    config,
    lib,
    osConfig ? null,
    pkgs,
    ...
  }: let
    secrets = lib.optionalAttrs (osConfig != null) osConfig.sops.secrets;
  in {
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
          # Hosts that are not recipients of personal.yaml fall back to Bitwarden.
          passwordCommand =
            if secrets ? baikal-admin-password
            then [(lib.getExe' pkgs.coreutils "cat") secrets.baikal-admin-password.path]
            else ["bws-get" "baikal/admin-password"];
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
