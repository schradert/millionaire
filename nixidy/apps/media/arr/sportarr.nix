{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "sportarr.${domain}";
    port = 1867;
    # The app writes /config as its own user; the image's `sportarr` is 13001 but it is
    # started as nobody like the other *arr apps, so the shared media volumes need no chown.
    nobody = 65534;
    retentionDays = 30;
  in {
    portal.apps.sportarr.groups = ["admin"];
    gatus.endpoints.sportarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.sportarr = {
      namespace = "media";
      volsync.pvcs.sportarr.title = "sportarr";
      # Idempotent post-sync bootstrap (apps/app-bootstrap sportarr, >= 0.24.0): root folder, qBittorrent,
      # Prowlarr's sync, and what to follow. Monitoring starts from now ("Future"; "All" would search every
      # match ever played) and Sportarr deletes an event's files retentionDays after it aired: Ceph is small
      # and the volume is a 250Gi quota, not a library to keep.
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-sportarr) {
        image = with pinned.images.app-bootstrap-sportarr; "${repository}:${tag}@${digest}";
        args = ["sportarr"];
        env = {
          SPORTARR_API_KEY_FILE = "/secrets/sportarr/apikey";
          PROWLARR_API_KEY_FILE = "/secrets/prowlarr/apikey";
          QBITTORRENT_PASSWORD_FILE = "/secrets/qbittorrent/password";
          SPORTARR_RETENTION_DAYS = toString retentionDays;
          # Wrexham AFC in every competition the metadata service lists it in.
          SPORTARR_TEAMS = builtins.toJSON [
            {
              name = "Wrexham";
              sport = "Soccer";
            }
          ];
          # Every match of the league, whoever plays.
          SPORTARR_LEAGUES = builtins.toJSON [
            {
              name = "English Premier League";
              sport = "Soccer";
              monitor = "Future";
            }
          ];
        };
        secrets = {
          sportarr = "sportarr-apikey";
          prowlarr = "prowlarr-apikey";
          qbittorrent = "qbittorrent-admin";
        };
      };
      # Header auth (config.xml) trusts X-Auth-Request-User from whoever sets it, so only oauth2-proxy
      # (UI), the apps that use the API key (Prowlarr's sync, Maintainerr, the bootstrap Job, the e2e Job) and
      # the kubelet/Prometheus may reach it.
      resources.ciliumNetworkPolicies.sportarr.spec = {
        endpointSelector.matchLabels."app.kubernetes.io/name" = "sportarr";
        ingress = [
          {fromEntities = ["host"];}
          {
            fromEndpoints = [
              {
                matchLabels = {
                  "k8s:io.kubernetes.pod.namespace" = "identity";
                  "app.kubernetes.io/name" = "oauth2-proxy";
                };
              }
              {matchLabels."app.kubernetes.io/name" = "prowlarr";}
              {matchLabels."app.kubernetes.io/name" = "maintainerr";}
              {matchLabels."batch.kubernetes.io/job-name" = "sportarr-bootstrap";}
              {matchLabels."app.kubernetes.io/name" = "media-e2e";}
              {
                matchLabels = {
                  "k8s:io.kubernetes.pod.namespace" = "observability";
                  "app.kubernetes.io/name" = "gatus";
                };
              }
            ];
            toPorts = lib.toList {
              ports = lib.toList {
                port = toString port;
                protocol = "TCP";
              };
            };
          }
        ];
      };
      helm.releases.sportarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.sportarr = {
            annotations."reloader.stakater.com/auto" = "true";
            # RWO config volume: a rolling update deadlocks on Multi-Attach.
            strategy = "Recreate";
            pod.securityContext = {
              runAsUser = nobody;
              runAsGroup = nobody;
              fsGroup = nobody;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            # The API key and the auth mode live in config.xml, not in the environment (the
            # Sportarr__ApiKey variable only tells the middleware a key exists). Seed the
            # generated key and header auth (oauth2-proxy) before the app first reads the file,
            # and put them back on every start, so the instance is never reachable unauthenticated.
            initContainers.config = {
              image = pinned.images.sportarr;
              command = ["bash" "-c"];
              args = [
                ''
                  set -eu
                  f=/config/config.xml
                  if [ ! -f "$f" ]; then
                    printf '<?xml version="1.0" encoding="utf-8"?>\n<Config>\n  <ApiKey>%s</ApiKey>\n  <AuthenticationMethod>External</AuthenticationMethod>\n  <AuthenticationRequired>Enabled</AuthenticationRequired>\n</Config>\n' "$Sportarr__ApiKey" > "$f"
                  else
                    sed -i -E \
                      -e "s|<ApiKey>[^<]*</ApiKey>|<ApiKey>$Sportarr__ApiKey</ApiKey>|" \
                      -e 's|<AuthenticationMethod>[^<]*</AuthenticationMethod>|<AuthenticationMethod>External</AuthenticationMethod>|' \
                      -e 's|<AuthenticationRequired>[^<]*</AuthenticationRequired>|<AuthenticationRequired>Enabled</AuthenticationRequired>|' "$f"
                  fi
                ''
              ];
              envFrom = [{secretRef.name = "sportarr";}];
            };
            containers.sportarr = {
              image = pinned.images.sportarr;
              envFrom = [{secretRef.name = "sportarr";} {configMapRef.name = "sportarr";}];
              probes = let
                ping = {
                  enabled = true;
                  custom = true;
                  spec.httpGet = {
                    path = "/ping";
                    inherit port;
                  };
                };
              in {
                liveness = ping;
                readiness = ping;
                startup = ping // {spec = ping.spec // {failureThreshold = 60;};};
              };
            };
          };
          service.sportarr.ports.http.port = port;
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "5Gi";
              globalMounts = [{path = "/config";}];
            };
            tmpfs = {
              type = "emptyDir";
              globalMounts = lib.toList {
                path = "/tmp";
                subPath = "tmp";
              };
            };
            media-sports = {
              type = "persistentVolumeClaim";
              existingClaim = "media-sports";
              advancedMounts.sportarr.sportarr = [{path = "/media/sports";}];
            };
            media-downloads = {
              type = "persistentVolumeClaim";
              existingClaim = "media-downloads";
              advancedMounts.sportarr.sportarr = [{path = "/media/downloads";}];
            };
          };
          configMaps.sportarr.data = {
            Sportarr__DataPath = "/config";
            Sportarr__Port = toString port;
            # nobody has no home: .NET keeps its data-protection keys there.
            HOME = "/config";
            TZ = "UTC";
          };
          route.sportarr = {
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
      # Random once, never refreshed: the init container writes it into config.xml.
      resources.passwords.sportarr-apikey.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = true;
        allowRepeat = true;
      };
      resources.externalSecrets.sportarr-apikey.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "sportarr-apikey";
          };
          rewrite = lib.toList {
            regexp = {
              source = "password";
              target = "apikey";
            };
          };
        };
      };
      resources.externalSecrets.sportarr.spec.data = lib.toList {
        secretKey = "Sportarr__ApiKey";
        remoteRef.key = "sportarr-apikey";
        remoteRef.property = "apikey";
        sourceRef.storeRef.name = "kubernetes-media";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
    };
    # Header auth trusts X-Auth-Request-User, so only oauth2-proxy may carry it: the route
    # above is the only way in.
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://sportarr.media.svc.cluster.local:${toString port}";
      namespace = "media";
    };
  };
}
