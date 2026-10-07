{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "radarr.${domain}";
    port = 80;
  in {
    gatus.endpoints.radarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.radarr = {
      namespace = "media";
      postgres.enable = true;
      volsync.pvcs.radarr.title = "radarr";
      helm.releases.radarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.radarr = {
            annotations."reloader.stakater.com/auto" = "true";
            # Rootless image; the volume mounts root-owned.
            pod.securityContext = {
              runAsUser = 65534;
              runAsGroup = 65534;
              fsGroup = 65534;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.radarr = {
              image.repository = "ghcr.io/home-operations/radarr";
              image.tag = "6.1.1.10317";
              image.digest = "sha256:5e08c0eefd2770d1d29395c4f84fe5bf7dfc3a986598021306a5d8ac017a3989";
              envFrom = [{secretRef.name = "radarr";} {configMapRef.name = "radarr";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.radarr.ports.http.port = port;
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
            };
            tmpfs = {
              type = "emptyDir";
              globalMounts = lib.toList {
                path = "/tmp";
                subPath = "tmp";
              };
            };
            media-movies = {
              type = "persistentVolumeClaim";
              existingClaim = "media-movies";
              advancedMounts.radarr.radarr = [{path = "/media/movies";}];
            };
            media-downloads = {
              type = "persistentVolumeClaim";
              existingClaim = "media-downloads";
              advancedMounts.radarr.radarr = [{path = "/media/downloads";}];
            };
          };
          configMaps.radarr.data = {
            RADARR__APP__INSTANCENAME = "Radarr";
            RADARR__AUTH__METHOD = "External";
            RADARR__AUTH__REQUIRED = "DisabledForLocalAddresses";
            RADARR__LOG__DBENABLED = "False";
            RADARR__LOG__LEVEL = "info";
            RADARR__SERVER__PORT = builtins.toString port;
            RADARR__UPDATE__BRANCH = "develop";
            RADARR__POSTGRES__USER = "radarr";
            RADARR__POSTGRES__HOST = "radarr-rw";
          };
          route.radarr = {
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
      # Random once, never refreshed: the app persists it as its own key.
      resources.passwords.radarr-apikey.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = true;
        allowRepeat = true;
      };
      resources.externalSecrets.radarr-apikey.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "radarr-apikey";
          };
          rewrite = lib.toList {
            regexp = {
              source = "password";
              target = "apikey";
            };
          };
        };
      };
      resources.externalSecrets.radarr.spec.data = [
        {
          secretKey = "RADARR__AUTH__APIKEY";
          remoteRef.key = "radarr-apikey";
          remoteRef.property = "apikey";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "RADARR__POSTGRES__PASSWORD";
          remoteRef.key = "radarr-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://radarr.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
