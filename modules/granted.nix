{lib, pkgs, ...}: {
  home.packages = with pkgs; [awscli2 granted];
  home.sessionVariables = {
    GRANTED_ALIAS_CONFIGURED = "true";
    GRANTED_DISABLE_UPDATE_CHECK = "true";
    GRANTED_ENABLE_AUTO_RESASSUME = "true";
  };
  home.shellAliases.assume = "source ${pkgs.granted}/bin/assume";
}
