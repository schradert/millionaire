{
  imports = [
    ./finance/actual.nix
    ./finance/firefly.nix
    ./finance/sure.nix
    ./health/mealie.nix
    ./home/home-assistant.nix
    ./identity/keycloak.nix
    ./identity/keycloak-operator.nix
    ./identity/oauth2-proxy.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
    health = {};
    home = {};
    identity = {};
  };
}
