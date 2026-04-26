{
  imports = [
    ./development/forgejo.nix
    ./development/windmill.nix
    ./finance/actual.nix
    ./finance/firefly.nix
    ./finance/sure.nix
    ./health/mealie.nix
    ./home/baikal.nix
    ./home/home-assistant.nix
    ./home/homepage.nix
    ./home/syncthing.nix
    ./home/webdav.nix
    ./home/zwave-js-ui.nix
    ./identity/keycloak.nix
    ./identity/keycloak-operator.nix
    ./identity/oauth2-proxy.nix
    ./printing/mainsail.nix
    ./printing/spoolman.nix
    ./printing/obico.nix
    ./printing/mooncord.nix
    ./printing/mobileraker-companion.nix
    ./printing/prometheus-klipper-exporter.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    development = {};
    finance = {};
    health = {};
    home = {};
    identity = {};
    printing = {};
  };
}
