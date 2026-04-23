{
  imports = [
    ./finance/actual.nix
    ./finance/firefly.nix
    ./finance/sure.nix
    ./health/mealie.nix
    ./home/home-assistant.nix
    ./home/zwave-js-ui.nix
    ./identity/keycloak.nix
    ./identity/keycloak-operator.nix
    ./identity/oauth2-proxy.nix
    ./media/audiobookshelf.nix
    ./media/immich.nix
    ./media/jellyfin.nix
    ./media/jitsi.nix
    ./media/kavita.nix
    ./media/komga.nix
    # TODO obs-studio: currently a dotfiles-style NixOS config, not nixidy.
    # See https://github.com/Niek/obs-web to deploy on kubernetes instead.
    # ./media/obs-studio.nix
    ./media/owncast.nix
    ./media/ryot.nix
    ./media/shoko.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
    health = {};
    home = {};
    identity = {};
    media = {};
  };
}
