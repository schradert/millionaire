{config, ...}: {
  nixidy = {charts, lib, ...}: let
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
          controllers.seerr.containers.seerr = {
            image.repository = "ghcr.io/seerr-team/seerr";
            image.tag = "develop";
            image.digest = "sha256:e49a2f222e48c7ccc30103b51cace3ef47111f57c251bca0366f2abf7e6f831e";
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
