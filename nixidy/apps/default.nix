{
  imports = [
    ./finance/actual.nix
    ./finance/firefly.nix
    ./health/mealie.nix
    ./identity/hydra.nix
    ./identity/keto.nix
    ./identity/kratos.nix
    ./identity/oathkeeper.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
    health = {};
    identity = {};
  };
}
