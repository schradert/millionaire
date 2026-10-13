# What the e2e `proxy` family checks against: the oauth2-proxy upstream table (host, allowed
# groups, namespace) and the portal tile catalog, both rendered from the same declarations the
# cluster is built from, so the expected group of a route is never written down twice. Mounted
# read-only at /config/catalog in the e2e Job (nixidy/apps/e2e.nix).
{...}: {
  nixidy = {
    config,
    lib,
    pinned,
    ...
  }: {
    applications.e2e = lib.mkIf ((pinned.images.e2e or null) != null) {
      namespace = "e2e";
      resources.configMaps.e2e-catalog.data = {
        "proxy.json" = builtins.toJSON (lib.mapAttrsToList (host: u: {
            inherit host;
            inherit (u) groups namespace;
          })
          config.oauth2Proxy.upstreams);
        "portal.json" = builtins.toJSON (map (a: {inherit (a) name url groups section;}) config.portal.catalog);
      };
    };
  };
}
