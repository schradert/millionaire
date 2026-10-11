{...}: {
  nixidy = {
    charts,
    pinned,
    ...
  }: {
    # API only (no UI): in-cluster health check, no tile.
    portal.apps.flaresolverr.enable = false;
    gatus.endpoints.flaresolverr = {
      url = "http://flaresolverr.media.svc.cluster.local:8191/health";
      group = "internal";
    };
    applications.flaresolverr = {
      namespace = "media";
      helm.releases.flaresolverr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.flaresolverr.containers.flaresolverr = {
            image = pinned.images.flaresolverr;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.flaresolverr.ports.http.port = 8191;
        };
      };
    };
  };
}
