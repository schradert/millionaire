{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "spoolman.${domain}";
  in {
    gatus.endpoints.spoolman = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.spoolman = {
      namespace = "printing";
      volsync.pvcs.spoolman.title = "spoolman";
      helm.releases.spoolman = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.spoolman = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.spoolman = {
              image.repository = "ghcr.io/donkie/spoolman";
              image.tag = "v0.22.1";
              env.SPOOLMAN_DB_TYPE = "sqlite";
              env.SPOOLMAN_DIR = "/data";
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.spoolman.ports.http.port = 8000;
          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = lib.toList {path = "/data";};
          };
        };
      };

      resources.httpRoutes.spoolman.spec = {
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

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://spoolman.printing.svc.cluster.local:8000";
      namespace = "printing";
    };
  };
}
