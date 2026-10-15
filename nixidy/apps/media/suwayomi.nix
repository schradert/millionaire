# Suwayomi (github.com/Suwayomi/Suwayomi-Server): manga acquisition. It runs Mihon/Tachiyomi
# source extensions and downloads chapters as CBZ (with ComicInfo.xml) into media-manga, which
# Komga and Kavita serve as their "Manga" libraries (Ryot follows Komga's reading progress).
# Chosen over Kaizoku (archived) and Mangarr (early, single-maintainer). Single-user with no SSO:
# oauth2-proxy's admin gate is the login, and AUTH_MODE stays `none` behind it.
# Sources come from extension stores, which are third-party: none is configured by default.
# Add store index URLs to `extensionStores` (docs/manual-steps.md 14).
{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "suwayomi.${domain}";
    port = 4567;
    extensionStores = [];
    data = "/home/suwayomi/.local/share/Tachidesk";
  in
    lib.mkIf (pinned.images ? suwayomi) {
      portal.apps.suwayomi.groups = ["admin"];
      gatus.endpoints.suwayomi = {
        url = "https://${hostname}";
        group = "internal";
        conditions = ["[STATUS] == any(200, 302, 401)"];
      };
      applications.suwayomi = {
        namespace = "media";
        volsync.pvcs.suwayomi.title = "suwayomi";
        helm.releases.suwayomi = {
          chart = charts.bjw-s-labs.app-template-patched;
          values = {
            controllers.suwayomi = {
              pod.securityContext = {
                runAsUser = 1000;
                runAsGroup = 1000;
                fsGroup = 1000;
                fsGroupChangePolicy = "OnRootMismatch";
              };
              containers.suwayomi = {
                image = pinned.images.suwayomi;
                env = {
                  TZ = "America/Los_Angeles";
                  BIND_PORT = toString port;
                  AUTH_MODE = "none";
                  WEB_UI_ENABLED = "true";
                  DOWNLOAD_AS_CBZ = "true";
                  # The embedded Chromium (KCEF) is the heavy part; FlareSolverr handles Cloudflare.
                  KCEF_ENABLED = "false";
                  FLARESOLVERR_ENABLED = "true";
                  FLARESOLVERR_URL = "http://flaresolverr.media.svc.cluster.local:8191";
                  MAX_SOURCES_IN_PARALLEL = "3";
                  EXTENSION_STORES = builtins.toJSON extensionStores;
                };
                probes.liveness.enabled = true;
                probes.readiness.enabled = true;
                probes.startup = {
                  enabled = true;
                  spec.failureThreshold = 60;
                };
                resources = {
                  requests = {
                    cpu = "20m";
                    memory = "384Mi";
                  };
                  limits.memory = "1536Mi";
                };
              };
            };
            service.suwayomi.ports.http.port = port;
            persistence = {
              data = {
                type = "persistentVolumeClaim";
                accessMode = "ReadWriteOnce";
                size = "2Gi";
                globalMounts = [{path = data;}];
              };
              media-manga = {
                type = "persistentVolumeClaim";
                existingClaim = "media-manga";
                globalMounts = [{path = "${data}/downloads";}];
              };
            };
            route.suwayomi = {
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
        url = "http://suwayomi.media.svc.cluster.local:${toString port}";
        namespace = "media";
        # The web UI's GraphQL subscriptions (downloads, updates).
        websocket = true;
      };
    };
}
