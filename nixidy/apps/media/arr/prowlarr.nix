{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "prowlarr.${domain}";
    port = 80;
  in {
    portal.apps.prowlarr.groups = ["admin"];
    gatus.endpoints.prowlarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.prowlarr = {
      namespace = "media";
      # Idempotent post-sync bootstrap (apps/app-bootstrap arr, >= 0.15.0): root folders and
      # the qBittorrent download client in Sonarr/Radarr/Lidarr, and Prowlarr's application
      # sync to them. API keys are the generated <app>-apikey Secrets.
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-arr) {
        image = with pinned.images.app-bootstrap-arr; "${repository}:${tag}@${digest}";
        args = ["arr"];
        env = {
          SONARR_API_KEY_FILE = "/secrets/sonarr/apikey";
          RADARR_API_KEY_FILE = "/secrets/radarr/apikey";
          LIDARR_API_KEY_FILE = "/secrets/lidarr/apikey";
          PROWLARR_API_KEY_FILE = "/secrets/prowlarr/apikey";
          QBITTORRENT_PASSWORD_FILE = "/secrets/qbittorrent/password";
        };
        secrets = {
          sonarr = "sonarr-apikey";
          radarr = "radarr-apikey";
          lidarr = "lidarr-apikey";
          prowlarr = "prowlarr-apikey";
          qbittorrent = "qbittorrent-admin";
        };
      };
      postgres = {
        enable = true;
        extraDatabases = ["prowlarr-log"];
      };
      volsync.pvcs.prowlarr.title = "prowlarr";
      helm.releases.prowlarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.prowlarr = {
            annotations."reloader.stakater.com/auto" = "true";
            # Rootless image; the volume mounts root-owned.
            pod.securityContext = {
              runAsUser = 65534;
              runAsGroup = 65534;
              fsGroup = 65534;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            # Prometheus exporter: scrapes the app's own API with its key.
            containers.exportarr = {
              image = pinned.images.exportarr;
              args = ["prowlarr"];
              env = {
                PORT = "9707";
                URL = "http://localhost:${toString port}";
                APIKEY.valueFrom.secretKeyRef = {
                  name = "prowlarr";
                  key = "PROWLARR__AUTH__APIKEY";
                };
              };
            };
            containers.prowlarr = {
              image = pinned.images.prowlarr;
              envFrom = [{secretRef.name = "prowlarr";} {configMapRef.name = "prowlarr";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.prowlarr.ports = {
            http.port = port;
            metrics.port = 9707;
          };
          serviceMonitor.prowlarr = {
            serviceName = "prowlarr";
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
            tmpfs.type = "emptyDir";
          };
          configMaps.prowlarr.data = {
            PROWLARR__APP__INSTANCENAME = "prowlarr";
            PROWLARR__AUTH__METHOD = "External";
            PROWLARR__AUTH__REQUIRED = "DisabledForLocalAddresses";
            PROWLARR__LOG__DBENABLED = "False";
            PROWLARR__LOG__LEVEL = "info";
            PROWLARR__SERVER__PORT = builtins.toString port;
            PROWLARR__UPDATE__BRANCH = "develop";
            PROWLARR__POSTGRES__USER = "prowlarr";
            PROWLARR__POSTGRES__MAINDB = "prowlarr";
            PROWLARR__POSTGRES__LOGDB = "prowlarr-log";
            PROWLARR__POSTGRES__HOST = "prowlarr-rw";
          };
          route.prowlarr = {
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
      resources.passwords.prowlarr-apikey.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = true;
        allowRepeat = true;
      };
      resources.externalSecrets.prowlarr-apikey.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "prowlarr-apikey";
          };
          rewrite = lib.toList {
            regexp = {
              source = "password";
              target = "apikey";
            };
          };
        };
      };
      resources.externalSecrets.prowlarr.spec.data = [
        {
          secretKey = "PROWLARR__AUTH__APIKEY";
          remoteRef.key = "prowlarr-apikey";
          remoteRef.property = "apikey";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "PROWLARR__POSTGRES__PASSWORD";
          remoteRef.key = "prowlarr-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://prowlarr.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
