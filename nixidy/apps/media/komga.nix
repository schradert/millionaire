{config, ...}: {
  # NOTE: Komga uses an embedded H2/SQLite DB by default, no Postgres support.
  # The config PVC (which contains the DB) is backed up via volsync.
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "komga.${domain}";
  in {
    gatus.endpoints.komga = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.komga = {
      namespace = "media";
      volsync.pvcs.komga.title = "komga";
      helm.releases.komga = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.komga.containers.komga = {
            image.repository = "gotson/komga";
            image.tag = "1.24.1";
            image.digest = "sha256:a84a0424e2f8235ba9373ed10b9b903e0feecdbb500a1b4aebac01f08e9e57db";
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.komga.ports.http.port = 25600;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/config";}];
          };
          persistence.media-comics = {
            type = "persistentVolumeClaim";
            existingClaim = "media-comics";
            advancedMounts.komga.komga = [{path = "/media/comics"; readOnly = true;}];
          };
          route.komga = {
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
      url = "http://komga.media.svc.cluster.local:25600";
      namespace = "media";
    };
  };
}
