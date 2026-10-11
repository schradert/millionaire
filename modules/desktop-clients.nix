# Desktop apps for services outside the media stack: Bitwarden (hosted vault;
# the macOS cask is signed, so Touch ID unlock and browser integration work)
# and the Home Assistant companion (macOS only; Linux uses the web UI).
{
  darwin = {
    config,
    lib,
    ...
  }: {
    homebrew.casks = lib.mkIf config.profiles.workstation.enable ["bitwarden" "home-assistant"];
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    home.packages = lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && config.profiles.client.enable) [pkgs.bitwarden-desktop];
  };
}
