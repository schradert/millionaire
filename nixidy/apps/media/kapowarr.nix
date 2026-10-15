# Kapowarr (github.com/Casvt/Kapowarr): comics acquisition into media-comics, read in Komga and
# Kavita. Chosen over Mylar3: actively released (V1.3.x in 2026, Mylar3's last release is 2025),
# and it downloads from GetComics directly, so it works without Usenet or torrent indexers; posts
# that are torrents go to qBittorrent. No Prowlarr sync exists for it (Prowlarr has no Kapowarr app).
# Single-user with no SSO: oauth2-proxy's admin gate is the login. The bootstrap
# (apps/app-bootstrap kapowarr) sets the download folder, FlareSolverr, the root folder and qBittorrent.
# Searching needs a ComicVine API key (user-provided): `credentials` below, Bitwarden
# `kapowarr/comicvine-api-key` (docs/manual-steps.md 14).
{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "kapowarr.${domain}";
    port = 5656;
    credentials = false;
  in
    lib.mkIf (pinned.images ? kapowarr) {
      portal.apps.kapowarr.groups = ["admin"];
      gatus.endpoints.kapowarr = {
        url = "https://${hostname}";
        group = "internal";
        conditions = ["[STATUS] == any(200, 302, 401)"];
      };
      applications.kapowarr = {
        namespace = "media";
        volsync.pvcs.kapowarr.title = "kapowarr";
        bootstrap = lib.mkIf (pinned.images ? app-bootstrap-kapowarr) {
          image = with pinned.images.app-bootstrap-kapowarr; "${repository}:${tag}@${digest}";
          args = ["kapowarr"];
          env =
            {
              QBITTORRENT_PASSWORD_FILE = "/secrets/qbittorrent/password";
            }
            // lib.optionalAttrs credentials {COMICVINE_API_KEY_FILE = "/secrets/comicvine/api-key";};
          secrets =
            {qbittorrent = "qbittorrent-admin";}
            // lib.optionalAttrs credentials {comicvine = "kapowarr-comicvine";};
        };
        resources.externalSecrets.kapowarr-comicvine = lib.mkIf credentials {
          spec.data = lib.toList {
            secretKey = "api-key";
            remoteRef.key = "kapowarr/comicvine-api-key";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          };
        };
        helm.releases.kapowarr = {
          chart = charts.bjw-s-labs.app-template-patched;
          values = {
            controllers.kapowarr = {
              pod.securityContext = {
                runAsUser = 65534;
                runAsGroup = 65534;
                fsGroup = 65534;
                fsGroupChangePolicy = "OnRootMismatch";
              };
              containers.kapowarr = {
                image = pinned.images.kapowarr;
                # As the pod's user (the entrypoint's gosu wants root); the download folder lives on
                # the volume qBittorrent shares, and Kapowarr refuses a folder that does not exist.
                command = ["sh" "-c"];
                args = ["mkdir -p /media/downloads/kapowarr && exec python3 /app/Kapowarr.py --DatabaseFolder /app/db --LogFolder /tmp/logs"];
                probes.liveness.enabled = true;
                probes.readiness.enabled = true;
                resources = {
                  requests = {
                    cpu = "10m";
                    memory = "96Mi";
                  };
                  limits.memory = "512Mi";
                };
              };
            };
            service.kapowarr.ports.http.port = port;
            persistence = {
              db = {
                type = "persistentVolumeClaim";
                accessMode = "ReadWriteOnce";
                size = "1Gi";
                globalMounts = [{path = "/app/db";}];
              };
              tmp = {
                type = "emptyDir";
                globalMounts = [{path = "/tmp";}];
              };
              media-comics = {
                type = "persistentVolumeClaim";
                existingClaim = "media-comics";
                globalMounts = [{path = "/media/comics";}];
              };
              media-downloads = {
                type = "persistentVolumeClaim";
                existingClaim = "media-downloads";
                globalMounts = [{path = "/media/downloads";}];
              };
            };
            route.kapowarr = {
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
      oauth2Proxy.upstreams.${hostname} = {
        url = "http://kapowarr.media.svc.cluster.local:${toString port}";
        namespace = "media";
      };
    };
}
