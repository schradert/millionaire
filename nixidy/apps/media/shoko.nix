{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "shoko.${domain}";
  in {
    gatus.endpoints.shoko = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.shoko = {
      namespace = "media";
      # Shoko has no OIDC: the UI stays behind oauth2-proxy and still asks for
      # Shoko's own login. The bootstrap finishes the first-run wizard with this
      # admin (apps/app-bootstrap shoko, >= 0.13.0).
      generatedSecrets.shoko-admin = {
        key = "password";
        bitwarden = "shoko/admin-password";
      };
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-shoko) {
        image = with pinned.images.app-bootstrap-shoko; "${repository}:${tag}@${digest}";
        args = ["shoko"];
        env = {
          SHOKO_URL = "http://shoko.media.svc.cluster.local:8111";
          ADMIN_USER = "admin";
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
        };
        secrets.admin = "shoko-admin";
      };
      volsync.pvcs.shoko.title = "shoko";
      helm.releases.shoko = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.shoko.containers.shoko = {
            image = pinned.images.shoko;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.shoko.ports.http.port = 8111;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/home/shoko/.shoko";}];
          };
          persistence.media-tv = {
            type = "persistentVolumeClaim";
            existingClaim = "media-tv";
            advancedMounts.shoko.shoko = [
              {
                path = "/media/tv";
                readOnly = true;
              }
            ];
          };
          route.shoko = {
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
      url = "http://shoko.media.svc.cluster.local:8111";
      namespace = "media";
    };
  };
}
