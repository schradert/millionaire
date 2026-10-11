# Brave with the Bitwarden extension (installed from the Chrome Web Store via
# External Extensions). macOS installs Brave from the cask (modules/default.nix).
# Unported: Zen (no home-manager module), Floccus (docs/connections.md).
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
      extensions = [{id = "nngceckbapebfimnlniiiahkandclblb";}];
    };
  };
}
