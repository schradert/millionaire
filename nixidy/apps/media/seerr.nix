{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "seerr.${domain}";
  in {
    gatus.endpoints.seerr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.seerr = {
      namespace = "media";
      volsync.pvcs.seerr.title = "seerr";
      helm.releases.seerr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          # The image runs as node (1000); the volume mounts root-owned.
          controllers.seerr.pod.securityContext = {
            fsGroup = 1000;
            fsGroupChangePolicy = "OnRootMismatch";
          };
          controllers.seerr.containers.seerr = {
            image = pinned.images.seerr;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.seerr.ports.http.port = 5055;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/app/config";}];
          };
          route.seerr = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "oauth2-proxy";
                namespace = "identity";
                port = 4180;
              };
            };
          };
        };
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://seerr.media.svc.cluster.local:5055";
      namespace = "media";
    };
  };
}
