{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "audiobookshelf.${domain}";
  in {
    gatus.endpoints.audiobookshelf = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.audiobookshelf = {
      namespace = "media";
      volsync.pvcs.audiobookshelf.title = "audiobookshelf";
      helm.releases.audiobookshelf = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.audiobookshelf.containers.audiobookshelf = {
            image = pinned.images.audiobookshelf;
            # The image listens on :80 unless told otherwise.
            env.PORT = "13378";
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.audiobookshelf.ports.http.port = 13378;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/config";}];
          };
          persistence.metadata = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/metadata";}];
          };
          persistence.media-audiobooks = {
            type = "persistentVolumeClaim";
            existingClaim = "media-audiobooks";
            advancedMounts.audiobookshelf.audiobookshelf = [{path = "/media/audiobooks";}];
          };
          persistence.media-podcasts = {
            type = "persistentVolumeClaim";
            existingClaim = "media-podcasts";
            advancedMounts.audiobookshelf.audiobookshelf = [{path = "/media/podcasts";}];
          };
          route.audiobookshelf = {
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
      url = "http://audiobookshelf.media.svc.cluster.local:13378";
      namespace = "media";
    };
  };
}
