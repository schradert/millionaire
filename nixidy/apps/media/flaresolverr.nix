{...}: {
  nixidy = {
    charts,
    pinned,
    ...
  }: {
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
