{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "actual.${domain}";
  in {
    gatus.endpoints.actual = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.actual = {
      namespace = "finance";
      volsync.pvcs.actual.title = "actual";
      helm.releases.actual = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.actual.containers.actual = {
            image = pinned.images.actual-server;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.actual.ports.http.port = 5006;
          persistence.data = {
            type = "persistentVolumeClaim";
            size = "1Gi";
            accessMode = "ReadWriteOnce";
          };
        };
      };
      resources.httpRoutes.actual.spec = {
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
      url = "http://actual.finance.svc.cluster.local:5006";
      namespace = "finance";
    };
  };
}
