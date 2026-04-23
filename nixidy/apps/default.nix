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
    ./media/arr/autobrr.nix
    ./media/arr/bazarr.nix
    ./media/arr/chaptarr.nix
    ./media/arr/lidarr.nix
    ./media/arr/prowlarr.nix
    ./media/arr/radarr.nix
    ./media/arr/recyclarr.nix
    ./media/arr/sabnzbd.nix
    ./media/arr/sonarr.nix
    ./media/flaresolverr.nix
    ./media/maintainerr.nix
    ./media/qbittorrent.nix
    ./media/seerr.nix
    ./media/storage.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
    health = {};
    home = {};
    identity = {};
    media = {};
  };
}
