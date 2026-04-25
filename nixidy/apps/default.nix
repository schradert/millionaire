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
    # Music stack — depends on the `media` namespace and `media-music` PVC from
    # the *arr-stack PR (#10) and on PR #11's media-server bundle for oauth2-proxy
    # ReferenceGrant + Jellyfin coexistence.
    ./media/maloja.nix
    ./media/multi-scrobbler.nix
    ./media/navidrome.nix
    # TODO music-assistant: enable alongside nixidy/system/network/multus.nix
    # once Multus is rolled out and a node has been confirmed on the speaker VLAN.
    # ./media/music-assistant.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    finance = {};
    health = {};
    home = {};
    identity = {};
    media = {};
  };
}
