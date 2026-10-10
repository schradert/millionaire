{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
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
          controllers.maintainerr.pod.securityContext = {
            # Image runs as node (1000); the volume mounts root-owned.
            runAsUser = 1000;
            runAsGroup = 1000;
            fsGroup = 1000;
            fsGroupChangePolicy = "OnRootMismatch";
          };
          controllers.maintainerr.containers.maintainerr = {
            # 3.x added Jellyfin/Emby support (2.x is Plex-only). Not backward
            # compatible: its DB migration is one-way.
            image = pinned.images.maintainerr;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup = {
              enabled = true;
              spec.failureThreshold = 60;
            };
          };
          # The server listens on 6246 (UI_PORT); nothing answers on :80, which
          # the default probes and the service were targeting.
          service.maintainerr.ports.http.port = 6246;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/opt/data";}];
          };
          persistence.tmpfs = {
            type = "emptyDir";
            globalMounts = lib.toList {
              path = "/tmp";
              subPath = "tmp";
            };
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
      url = "http://maintainerr.media.svc.cluster.local:6246";
      namespace = "media";
    };
  };
}
