{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "shoko.${domain}";
  in {
    gatus.endpoints.shoko = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.shoko = {
      namespace = "media";
      volsync.pvcs.shoko.title = "shoko";
      helm.releases.shoko = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.shoko.containers.shoko = {
            image.repository = "shokoanime/server";
            image.tag = "v5.3.1";
            image.digest = "sha256:8bfa235fc36a7147443679c242368f30a532e12de3f52e0de2dcc7743fa37044";
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.shoko.ports.http.port = 8111;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/home/shoko/.shoko";}];
          };
          persistence.media-tv = {
            type = "persistentVolumeClaim";
            existingClaim = "media-tv";
            advancedMounts.shoko.shoko = [{path = "/media/tv"; readOnly = true;}];
          };
          route.shoko = {
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
      url = "http://shoko.media.svc.cluster.local:8111";
      namespace = "media";
    };
  };
}
