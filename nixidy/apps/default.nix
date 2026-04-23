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
    ./printing/mainsail.nix
    ./printing/spoolman.nix
    ./printing/obico.nix
    ./printing/mooncord.nix
    ./printing/mobileraker-companion.nix
    ./printing/prometheus-klipper-exporter.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
    health = {};
    home = {};
    identity = {};
    printing = {};
  };
}
