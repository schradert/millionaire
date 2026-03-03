{
  system = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.profile == "work" && config.profiles.workstation.enable) {
      nixpkgs.overlays = [
        (_: prev: {
          # TODO why is it hanging on tests/customizations/test_waiters.py?
          awscli2 = prev.awscli2.overridePythonAttrs (old: {
            doCheck = false;
            disabledTestPaths = old.disabledTestPaths ++ ["tests/unit/customizations/test_waiters.py"];
          });
        })
      ];
    };
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.profile == "work" && config.profiles.workstation.enable) {
      home = {
        packages = with pkgs; [awscli2 granted];
        sessionVariables = {
          GRANTED_ALIAS_CONFIGURED = "true";
          GRANTED_DISABLE_UPDATE_CHECK = "true";
          GRANTED_ENABLE_AUTO_RESASSUME = "true";
        };
        shellAliases.assume = "source ${pkgs.granted}/bin/assume";
      };
    };
  };
}
