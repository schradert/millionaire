{
  imports = [
    ./finance/actual.nix
    ./finance/firefly.nix
    ./health/mealie.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
    health = {};
  };
}
