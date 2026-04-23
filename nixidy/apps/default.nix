{
  imports = [
    ./finance/actual.nix
    ./finance/firefly.nix
    ./finance/sure.nix
    ./health/mealie.nix
    ./home/home-assistant.nix
    ./home/logseq.nix
    ./home/org-bridge.nix
    ./home/org-storage.nix
    ./home/siyuan.nix
    ./home/zwave-js-ui.nix
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
