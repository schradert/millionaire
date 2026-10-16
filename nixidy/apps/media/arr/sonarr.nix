{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "sonarr.${domain}";
    port = 80;
  in {
    portal.apps.sonarr.groups = ["admin"];
    gatus.endpoints.sonarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.sonarr = {
      namespace = "media";
      postgres = {
        enable = true;
        avoidNodes = ["sirver"];
        extraDatabases = ["sonarr-log"];
      };
      volsync.pvcs.sonarr.title = "sonarr";
      helm.releases.sonarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.sonarr = {
            annotations."reloader.stakater.com/auto" = "true";
            # Rootless image; the volume mounts root-owned.
            # ntfy lives on hyena; pods don't resolve it (docs/observability.md).
            pod.hostAliases = lib.toList {
              ip = "100.64.0.1";
              hostnames = ["ntfy.${domain}"];
            };
            pod.securityContext = {
              runAsUser = 65534;
              runAsGroup = 65534;
              fsGroup = 65534;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            # Prometheus exporter: scrapes the app's own API with its key.
            containers.exportarr = {
              image = pinned.images.exportarr;
              args = ["sonarr"];
              env = {
                PORT = "9707";
                # Adds the download queue (queue_total) to the base series.
                ENABLE_ADDITIONAL_METRICS = "true";
                URL = "http://localhost:${toString port}";
                APIKEY.valueFrom.secretKeyRef = {
                  name = "sonarr";
                  key = "SONARR__AUTH__APIKEY";
                };
              };
            };
            containers.sonarr = {
              image = pinned.images.sonarr;
              envFrom = [{secretRef.name = "sonarr";} {configMapRef.name = "sonarr";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.sonarr.ports = {
            http.port = port;
            metrics.port = 9707;
          };
          serviceMonitor.sonarr = {
            serviceName = "sonarr";
            endpoints = lib.toList {
              port = "metrics";
              path = "/metrics";
              interval = "1m";
            };
          };
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
            SONARR__SERVER__ALLOWEDHOSTS = lib.concatStringsSep "," [hostname "sonarr.media.svc.cluster.local" "sonarr.media.svc" "sonarr.media" "sonarr" "localhost"];
            # Stable line: develop has already moved to v5, so the update check kept warning.
            SONARR__UPDATE__BRANCH = "main";
            SONARR__POSTGRES__USER = "sonarr";
            SONARR__POSTGRES__MAINDB = "sonarr";
            SONARR__POSTGRES__LOGDB = "sonarr-log";
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
      # Random once, never refreshed: the app persists it as its own key.
      resources.passwords.sonarr-apikey.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = true;
        allowRepeat = true;
      };
      resources.externalSecrets.sonarr-apikey.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "sonarr-apikey";
          };
          rewrite = lib.toList {
            regexp = {
              source = "password";
              target = "apikey";
            };
          };
        };
      };
      resources.externalSecrets.sonarr.spec.data = [
        {
          secretKey = "SONARR__AUTH__APIKEY";
          remoteRef.key = "sonarr-apikey";
          remoteRef.property = "apikey";
          sourceRef.storeRef.name = "kubernetes-media";
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
