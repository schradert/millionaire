{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "lidarr.${domain}";
    port = 80;
  in {
    gatus.endpoints.lidarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.lidarr = {
      namespace = "media";
      postgres.enable = true;
      volsync.pvcs.lidarr.title = "lidarr";
      helm.releases.lidarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.lidarr = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.lidarr = {
              image.repository = "ghcr.io/home-operations/lidarr";
              image.tag = "3.1.2.4902";
              image.digest = "sha256:dab0e07502a34436fc50c3e789388f0a29f8cbf681fb7a02ed703ad7c368a22c";
              envFrom = [{secretRef.name = "lidarr";} {configMapRef.name = "lidarr";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.lidarr.ports.http.port = port;
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
            };
            tmpfs = {
              type = "emptyDir";
              globalMounts = lib.toList {path = "/tmp"; subPath = "tmp";};
            };
            media-music = {
              type = "persistentVolumeClaim";
              existingClaim = "media-music";
              advancedMounts.lidarr.lidarr = [{path = "/media/music";}];
            };
            media-downloads = {
              type = "persistentVolumeClaim";
              existingClaim = "media-downloads";
              advancedMounts.lidarr.lidarr = [{path = "/media/downloads";}];
            };
          };
          configMaps.lidarr.data = {
            LIDARR__APP__INSTANCENAME = "lidarr";
            LIDARR__AUTH__METHOD = "External";
            LIDARR__AUTH__REQUIRED = "DisabledForLocalAddresses";
            LIDARR__LOG__DBENABLED = "False";
            LIDARR__LOG__LEVEL = "info";
            LIDARR__SERVER__PORT = builtins.toString port;
            LIDARR__UPDATE__BRANCH = "develop";
            LIDARR__POSTGRES__USER = "lidarr";
            LIDARR__POSTGRES__HOST = "lidarr-rw";
          };
          route.lidarr = {
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
      resources.externalSecrets.lidarr.spec.data = [
        {
          secretKey = "LIDARR__AUTH__APIKEY";
          remoteRef.key = "lidarr";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "LIDARR__POSTGRES__PASSWORD";
          remoteRef.key = "lidarr-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://lidarr.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
