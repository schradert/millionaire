{
  imports = [
    ./development/forgejo.nix
    ./development/windmill.nix
    ./finance/actual.nix
    ./finance/firefly.nix
    ./finance/sure.nix
    ./health/mealie.nix
    ./home/home-assistant.nix
    ./home/zwave-js-ui.nix
    ./identity/keycloak.nix
    ./identity/keycloak-operator.nix
    ./identity/oauth2-proxy.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    development = {};
    finance = {};
    health = {};
    home = {};
    identity = {};
  };
}
