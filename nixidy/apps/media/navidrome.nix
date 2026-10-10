{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "navidrome.${domain}";
    port = 4533;
  in {
    gatus.endpoints.navidrome = {
      url = "https://${hostname}/ping";
      group = "internal";
      conditions = ["[STATUS] == 200"];
    };
    applications.navidrome = {
      namespace = "media";
      volsync.pvcs.navidrome.title = "navidrome";
      helm.releases.navidrome = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.navidrome = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.navidrome = {
              image = pinned.images.navidrome;
              envFrom = [{configMapRef.name = "navidrome";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.navidrome.ports.http.port = port;
          persistence = {
            data = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "2Gi";
              globalMounts = [{path = "/data";}];
            };
            cache = {
              type = "emptyDir";
              globalMounts = lib.toList {path = "/data/cache";};
            };
            media-music = {
              type = "persistentVolumeClaim";
              existingClaim = "media-music";
              advancedMounts.navidrome.navidrome = [
                {
                  path = "/music";
                  readOnly = true;
                }
              ];
            };
          };
          configMaps.navidrome.data = {
            ND_DATAFOLDER = "/data";
            ND_MUSICFOLDER = "/music";
            ND_PORT = builtins.toString port;
            ND_BASEURL = "https://${hostname}";
            ND_LOGLEVEL = "info";
            ND_SCANSCHEDULE = "@every 1h";
            ND_SCANNER_GROUPALBUMRELEASES = "true";
            ND_ENABLESHARING = "true";
            ND_ENABLEDOWNLOADS = "true";
            ND_ENABLETRANSCODINGCONFIG = "true";
            # Reverse-proxy headers from gateway: trust X-Forwarded-* and identify the user
            # via the ReverseProxyUserHeader. Subsonic API uses its own per-request auth — do NOT
            # put oauth2-proxy in front of Navidrome (it breaks every mobile client).
            ND_REVERSEPROXYWHITELIST = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16";
            # ListenBrainz scrobble target points at Maloja's LB-compatible endpoint.
            # Maloja then proxy-forwards to real (pseudonymous) ListenBrainz.
            # Per-user LB tokens are configured in Navidrome's user UI; the token a user
            # supplies is their Maloja API key (which Maloja in turn relays under the user's
            # pseudonymous LB token, configured in Maloja).
            ND_LASTFM_ENABLED = "false";
            ND_LISTENBRAINZ_ENABLED = "true";
            ND_LISTENBRAINZ_BASEURL = "http://maloja.media.svc.cluster.local:42010/apis/listenbrainz/1/";
            # Smart playlists & similar-artist suggestions
            ND_DEEZER_ENABLED = "false";
            ND_SPOTIFY_ID = "";
            ND_SPOTIFY_SECRET = "";
          };
          route.navidrome = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
    };
  };
}
