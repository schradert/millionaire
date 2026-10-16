{config, ...}: {
  nixidy = {
    charts,
    lib,
    ntfyToken,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "cleanuparr.${domain}";
    port = 11011;
  in {
    # Also the answer to Huntarr (searches for missing and upgradable items): its repository was
    # deleted in February 2026 after reported authentication bypasses and exposed arr API keys, so
    # Cleanuparr's Seeker (Sonarr and Radarr) does that job at an indexer-friendly pace.
    portal.apps.cleanuparr = {
      groups = ["admin"];
      icon = "mdi-broom";
      description = "Removes stalled and malicious downloads; searches for missing and upgradable media";
    };
    gatus.endpoints.cleanuparr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.cleanuparr = {
      namespace = "media";
      ntfySecret = "publisher";
      generatedSecrets.cleanuparr-admin = {
        key = "password";
        bitwarden = "cleanuparr/admin-password";
      };
      volsync.pvcs.cleanuparr.title = "cleanuparr";
      # Idempotent post-sync bootstrap (apps/app-bootstrap cleanuparr): the break-glass account, the
      # Sonarr/Radarr/Lidarr and qBittorrent connections, conservative cleaning rules, the Seeker's
      # slow search for missing and upgradable items, and ntfy topic `media`. The UI is reached through
      # oauth2-proxy (admin), so the app's own login is off for the cluster's networks.
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-cleanuparr) {
        image = with pinned.images.app-bootstrap-cleanuparr; "${repository}:${tag}@${digest}";
        args = ["cleanuparr"];
        env =
          {
            CLEANUPARR_URL = "http://cleanuparr.media.svc.cluster.local:${toString port}";
            CLEANUPARR_PASSWORD_FILE = "/secrets/admin/password";
            SONARR_API_KEY_FILE = "/secrets/sonarr/apikey";
            RADARR_API_KEY_FILE = "/secrets/radarr/apikey";
            LIDARR_API_KEY_FILE = "/secrets/lidarr/apikey";
            QBITTORRENT_PASSWORD_FILE = "/secrets/qbittorrent/password";
            NTFY_URL = "https://ntfy.${domain}";
            NTFY_TOPIC = "media";
          }
          // lib.optionalAttrs ntfyToken.enable {NTFY_TOKEN_FILE = "/secrets/ntfy/token";};
        secrets =
          {
            admin = "cleanuparr-admin";
            sonarr = "sonarr-apikey";
            radarr = "radarr-apikey";
            lidarr = "lidarr-apikey";
            qbittorrent = "qbittorrent-admin";
          }
          // lib.optionalAttrs ntfyToken.enable {ntfy = "cleanuparr-ntfy";};
      };
      helm.releases.cleanuparr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.cleanuparr = {
            # Rootless: the image skips its user switching and only needs a writable /config.
            pod = {
              securityContext = {
                runAsUser = 65534;
                runAsGroup = 65534;
                fsGroup = 65534;
                fsGroupChangePolicy = "OnRootMismatch";
              };
              # ntfy lives on hyena; pods don't resolve it (docs/observability.md).
              hostAliases = lib.toList {
                ip = "100.64.0.1";
                hostnames = ["ntfy.${domain}"];
              };
            };
            containers.cleanuparr = {
              image = pinned.images.cleanuparr;
              resources.requests = {
                cpu = "20m";
                memory = "256Mi";
              };
              probes = {
                liveness = {
                  enabled = true;
                  custom = true;
                  spec = {
                    httpGet = {
                      path = "/health";
                      inherit port;
                    };
                    periodSeconds = 30;
                    timeoutSeconds = 10;
                  };
                };
                readiness = {
                  enabled = true;
                  custom = true;
                  spec.httpGet = {
                    path = "/health";
                    inherit port;
                  };
                };
                startup = {
                  enabled = true;
                  custom = true;
                  spec = {
                    httpGet = {
                      path = "/health";
                      inherit port;
                    };
                    periodSeconds = 5;
                    failureThreshold = 60;
                  };
                };
              };
            };
          };
          service.cleanuparr.ports.http.port = port;
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
          };
          route.cleanuparr = {
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
      url = "http://cleanuparr.media.svc.cluster.local:${toString port}";
      namespace = "media";
    };
  };
}
