{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && config.profiles.workstation.enable) {
      home.packages = [pkgs.codexbar];

      # codexbar's provider toggles/API keys live in ~/.config/codexbar/config.json
      # (handled via its own CLI below); everything else lives in the app's
      # NSUserDefaults domain, set declaratively through home-manager's
      # targets.darwin.defaults (still just `defaults import` under an activation
      # script — NSUserDefaults isn't a Nix-owned file, so removing a key here
      # won't unset it on the machine, only stop setting it going forward).
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

        # Keep browser-cookie/Keychain access enabled (this is the default; set explicitly).
        debugDisableKeychainAccess = false;
      };

      home.activation.codexbarProviders = lib.hm.dag.entryAfter ["writeBoundary"] ''
        codexbar="${pkgs.codexbar}/bin/codexbar"
        if [ -x "$codexbar" ]; then
          $DRY_RUN_CMD "$codexbar" config enable --provider claude
        fi
      '';
    };
  };
}
