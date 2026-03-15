{
  imports = [
    ./finance/actual.nix
    ./finance/firefly.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
  };
}
