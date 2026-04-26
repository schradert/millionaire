{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "sonarr.${domain}";
    port = 80;
  in {
    gatus.endpoints.sonarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.sonarr = {
      namespace = "media";
      postgres.enable = true;
      volsync.pvcs.sonarr.title = "sonarr";
      helm.releases.sonarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.sonarr = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.sonarr = {
              image.repository = "ghcr.io/home-operations/sonarr";
              image.tag = "4.0.17.2950";
              image.digest = "sha256:bdc787fe07bb7c0b6af9c030764902f70092ec9a426e52a36716d3a13917fe2d";
              envFrom = [{secretRef.name = "sonarr";} {configMapRef.name = "sonarr";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.sonarr.ports.http.port = port;
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
            media-tv = {
              type = "persistentVolumeClaim";
              existingClaim = "media-tv";
              advancedMounts.sonarr.sonarr = [{path = "/media/tv";}];
            };
            media-downloads = {
              type = "persistentVolumeClaim";
              existingClaim = "media-downloads";
              advancedMounts.sonarr.sonarr = [{path = "/media/downloads";}];
            };
          };
          configMaps.sonarr.data = {
            SONARR__APP__INSTANCENAME = "sonarr";
            SONARR__AUTH__METHOD = "External";
            SONARR__AUTH__REQUIRED = "DisabledForLocalAddresses";
            SONARR__LOG__DBENABLED = "False";
            SONARR__LOG__LEVEL = "info";
            SONARR__SERVER__PORT = builtins.toString port;
            SONARR__UPDATE__BRANCH = "develop";
            SONARR__POSTGRES__USER = "sonarr";
            SONARR__POSTGRES__HOST = "sonarr-rw";
          };
          route.sonarr = {
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
      resources.externalSecrets.sonarr.spec.data = [
        {
          secretKey = "SONARR__AUTH__APIKEY";
          remoteRef.key = "sonarr";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "SONARR__POSTGRES__PASSWORD";
          remoteRef.key = "sonarr-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://sonarr.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
