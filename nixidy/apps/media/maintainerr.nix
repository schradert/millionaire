{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "maintainerr.${domain}";
  in {
    gatus.endpoints.maintainerr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.maintainerr = {
      namespace = "media";
      volsync.pvcs.maintainerr.title = "maintainerr";
      helm.releases.maintainerr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.maintainerr.containers.maintainerr = {
            image.repository = "ghcr.io/jorenn92/maintainerr";
            image.tag = "2.19.0";
            image.digest = "sha256:bee84707edaf589cda3d18b6813cbfe3a137b52786210c3a28190e10910c1240";
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.maintainerr.ports.http.port = 80;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/opt/data";}];
          };
          persistence.tmpfs = {
            type = "emptyDir";
            globalMounts = lib.toList {path = "/tmp"; subPath = "tmp";};
          };
          route.maintainerr = {
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
      url = "http://maintainerr.media.svc.cluster.local:80";
      namespace = "media";
    };
  };
}
