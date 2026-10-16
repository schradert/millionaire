# CodexBar (menu-bar usage for AI coding providers), Claude only.
#
# Nothing is set up by hand: the provider list, the app's preferences and the login item are all
# declared here, and Claude is read through the `claude` CLI (`source = "cli"`), which runs
# Claude Code's own `/usage` with the login Claude Code already holds. Unlike the OAuth source it
# never reads Claude Code's Keychain item, so no Keychain prompt and no token to copy.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    app = "${pkgs.codexbar}/Applications/CodexBar.app";
    # `~/.config/codexbar/config.json`; only the providers listed here are touched
    # (https://github.com/steipete/CodexBar/blob/main/docs/configuration.md).
    providers = {
      version = 1;
      providers = [
        {
          id = "claude";
          enabled = true;
          source = "cli";
        }
      ];
    };
  in {
    config = lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && config.profiles.workstation.enable) {
      home.packages = [pkgs.codexbar];

      # App preferences are NSUserDefaults (`defaults import` on every switch). Removing a key here
      # does not unset it on the machine.
      targets.darwin.defaults."com.steipete.codexbar" = {
        refreshFrequency = "adaptive";
        claudeModelScopedWeeklyUsageVisible = true;

        mergeIcons = true;
        hidePersonalInfo = true;

        tokenCostUsageEnabled = true;
        tokenCostUsageHistoryDays = 365;

        sessionQuotaNotificationsEnabled = true;
        confettiOnWeeklyLimitResetsEnabled = true;
        statusChecksEnabled = true;

        # Default; explicit so the browser-cookie and Keychain paths stay available.
        debugDisableKeychainAccess = false;
      };

      # A real file (the app rewrites it atomically, which would replace a store symlink), 0600 as
      # the app writes it. Rewritten only when it differs, so the app's file watcher stays quiet.
      home.activation.codexbarConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
        dir="${config.xdg.configHome}/codexbar"
        want=${pkgs.writeText "codexbar-config.json" (builtins.toJSON providers)}
        $DRY_RUN_CMD mkdir -p "$dir"
        if ! ${pkgs.diffutils}/bin/cmp -s "$want" "$dir/config.json"; then
          $DRY_RUN_CMD install -m 600 "$want" "$dir/config.json"
        fi
      '';

      # Start at login (and now, on the switch) so the menu bar shows Claude usage without opening
      # the app. `claude` sits in the user profile, which launchd's PATH lacks.
      launchd.agents.codexbar = {
        enable = true;
        config = {
          ProgramArguments = ["/usr/bin/open" "-g" "-a" app];
          RunAtLoad = true;
          EnvironmentVariables.PATH = lib.concatStringsSep ":" ["${config.home.profileDirectory}/bin" "/usr/bin" "/bin"];
        };
      };
    };
  };
}
