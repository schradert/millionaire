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
    hostname = "seerr.${domain}";
  in {
    gatus.endpoints.seerr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.seerr = {
      namespace = "media";
      # Seerr has no native OIDC (checked at the pinned develop commit 25e376c: no
      # OIDC code in auth or settings routes), so it stays behind oauth2-proxy. Its
      # only admin path is the setup wizard's Jellyfin sign-in, which makes the
      # Jellyfin admin Seerr user 1. This job does that with the bootstrapped
      # Jellyfin `admin` account and tristan's email, enables all libraries and
      # finishes the wizard. Break-glass is that Jellyfin admin login
      # (Secret jellyfin-admin, Bitwarden jellyfin/admin-password); Seerr has no
      # separate admin password. Radarr/Sonarr are not wired (follow-up).
      # Idempotent post-sync bootstrap (apps/app-bootstrap seerr, >= 0.7.0).
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-seerr) {
        image = with pinned.images.app-bootstrap-seerr; "${repository}:${tag}@${digest}";
        args = ["seerr"];
        env = {
          SEERR_URL = "http://seerr.media.svc.cluster.local:5055";
          JELLYFIN_HOST = "jellyfin.media.svc.cluster.local";
          JELLYFIN_PORT = "8096";
          JELLYFIN_ADMIN_USER = "admin";
          JELLYFIN_ADMIN_PASSWORD_FILE = "/secrets/jellyfin/password";
          ADMIN_EMAIL = people.my.profiles.personal.email;
        };
        secrets.jellyfin = "jellyfin-admin";
      };
      volsync.pvcs.seerr.title = "seerr";
      helm.releases.seerr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          # The image runs as node (1000); the volume mounts root-owned.
          controllers.seerr.pod.securityContext = {
            fsGroup = 1000;
            fsGroupChangePolicy = "OnRootMismatch";
          };
          controllers.seerr.containers.seerr = {
            image = pinned.images.seerr;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.seerr.ports.http.port = 5055;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/app/config";}];
          };
          route.seerr = {
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
      url = "http://seerr.media.svc.cluster.local:5055";
      namespace = "media";
    };
  };
}
