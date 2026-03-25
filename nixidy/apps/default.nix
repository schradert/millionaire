{
  imports = [
    ./finance/actual.nix
    ./finance/firefly.nix
    ./finance/sure.nix
    ./health/mealie.nix
    ./identity/keycloak.nix
    ./identity/keycloak-operator.nix
    ./identity/oauth2-proxy.nix
    ./identity/oathkeeper.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
    health = {};
    identity = {};
  };
}
