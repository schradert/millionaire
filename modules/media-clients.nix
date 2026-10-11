# Desktop clients for the cluster's media apps. Jellyfin: delfin on Linux and
# the Jellyfin Media Player cask on macOS (nixpkgs' jellyfin-media-player is
# stuck on insecure qtwebengine 5). Feishin plays Navidrome (and Jellyfin
# music); immich-cli uploads to Immich. Audiobookshelf, Kavita and Komga have
# no desktop clients (web, OPDS: docs/ereader-opds.md).
# `immich-login`: immich-cli with tristan's API key (app-bootstrap immich, Bitwarden).
{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  darwin = {
    config,
    lib,
    ...
  }: {
    homebrew.casks = lib.mkIf config.profiles.workstation.enable ["jellyfin-media-player"];
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    linuxClient = pkgs.stdenv.hostPlatform.isLinux && config.profiles.client.enable;
  in {
    home.packages = with pkgs;
      lib.optionals (config.profiles.workstation.enable || linuxClient) [feishin]
      ++ lib.optionals config.profiles.workstation.enable [immich-cli]
      ++ lib.optionals linuxClient [delfin];
    home.shellAliases = lib.mkIf config.profiles.workstation.enable {
      immich-login = "immich login https://immich.${domain}/api \"$(bws-get immich/tristan/api-key)\"";
    };
  };
}
