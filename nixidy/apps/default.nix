{
  imports = [
    ./finance/actual.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
  };
}
