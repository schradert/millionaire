{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "maintainerr.${domain}";
  in {
    portal.apps.maintainerr.groups = ["admin"];
    gatus.endpoints.maintainerr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.maintainerr = {
      namespace = "media";
      volsync.pvcs.maintainerr.title = "maintainerr";
      # Idempotent post-sync bootstrap (apps/app-bootstrap maintainerr, >= 0.22.0): the Radarr, Sonarr
      # and Seerr connections (Jellyfin comes from jellyfin-bootstrap). Creates no rule group: rules
      # delete media, so they stay a deliberate choice.
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-maintainerr) {
        image = with pinned.images.app-bootstrap-maintainerr; "${repository}:${tag}@${digest}";
        args = ["maintainerr"];
        env = {
          RADARR_API_KEY_FILE = "/secrets/radarr/apikey";
          SONARR_API_KEY_FILE = "/secrets/sonarr/apikey";
          JELLYFIN_ADMIN_USER = "admin";
          JELLYFIN_ADMIN_PASSWORD_FILE = "/secrets/jellyfin/password";
          ADMIN_EMAIL = people.my.profiles.personal.email;
        };
        secrets = {
          radarr = "radarr-apikey";
          sonarr = "sonarr-apikey";
          jellyfin = "jellyfin-admin";
        };
      };
      # Maintainerr has no login and returns its settings (API key, Jellyfin key) to any caller, so
      # only oauth2-proxy (UI), the Jellyfin and Maintainerr bootstraps (configure it) and the e2e Job may reach it.
      resources.ciliumNetworkPolicies.maintainerr.spec = {
        endpointSelector.matchLabels."app.kubernetes.io/name" = "maintainerr";
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
              {matchLabels."batch.kubernetes.io/job-name" = "jellyfin-bootstrap";}
              {matchLabels."batch.kubernetes.io/job-name" = "maintainerr-bootstrap";}
              {matchLabels."app.kubernetes.io/name" = "media-e2e";}
            ];
            toPorts = lib.toList {
              ports = lib.toList {
                port = "6246";
                protocol = "TCP";
              };
            };
          }
        ];
      };
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
