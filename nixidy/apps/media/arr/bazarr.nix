{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "bazarr.${domain}";
  in {
    gatus.endpoints.bazarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.bazarr = {
      namespace = "media";
      volsync.pvcs.bazarr.title = "bazarr";
      helm.releases.bazarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.bazarr = {
            # Image runs as nobody (65534); the volume mounts root-owned.
            pod.securityContext = {
              runAsUser = 65534;
              runAsGroup = 65534;
              fsGroup = 65534;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.bazarr = {
              image = pinned.images.bazarr;
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup = {
                enabled = true;
                spec.failureThreshold = 60;
              };
            };
          };
          service.bazarr.ports.http.port = 6767;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
          };
          persistence.tmpfs = {
            type = "emptyDir";
            globalMounts = [
              {
                path = "/config/cache";
                subPath = "cache";
              }
              {
                path = "/config/log";
                subPath = "log";
              }
              {
                path = "/tmp";
                subPath = "tmp";
              }
            ];
          };
          persistence.media-movies = {
            type = "persistentVolumeClaim";
            existingClaim = "media-movies";
            advancedMounts.bazarr.bazarr = [
              {
                path = "/media/movies";
                readOnly = true;
              }
            ];
          };
          persistence.media-tv = {
            type = "persistentVolumeClaim";
            existingClaim = "media-tv";
            advancedMounts.bazarr.bazarr = [
              {
                path = "/media/tv";
                readOnly = true;
              }
            ];
          };
          route.bazarr = {
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
      url = "http://bazarr.media.svc.cluster.local:6767";
      namespace = "media";
    };
  };
}
