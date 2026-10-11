# Brave with the Bitwarden and Floccus extensions (installed from the Chrome Web
# Store via External Extensions; Floccus setup: docs/connections.md). macOS
# installs Brave from the cask (modules/default.nix). Unported: Zen (no
# home-manager module).
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    programs.brave = lib.mkIf config.profiles.workstation.enable {
      enable = true;
      package =
        if pkgs.stdenv.hostPlatform.isDarwin
        then null
        else pkgs.brave;
      extensions = [
        {id = "nngceckbapebfimnlniiiahkandclblb";} # Bitwarden
        {id = "fnaicdffflnofjppbagibeoednhnbjhg";} # Floccus
      ];
    };
  };
}
