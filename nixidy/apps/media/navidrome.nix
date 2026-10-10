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
    hostname = "navidrome.${domain}";
    port = 4533;
    # Navidrome has no native OIDC. Until the bootstrap image is pinned the whole host
    # stays behind oauth2-proxy with header auth OFF: an unclaimed instance lets the
    # first header-authenticated (or /auth/createAdmin) caller become admin.
    bootstrapped = pinned.images ? app-bootstrap-navidrome;
    # oauth2-proxy's nginx router sets this from the Keycloak preferred_username.
    userHeader = "X-Auth-Request-Preferred-Username";
    # Client-supplied copies of every identity header are stripped at the gateway.
    identityHeaders = [userHeader "X-Forwarded-Preferred-Username" "X-Forwarded-User" "X-Forwarded-Email" "Remote-User"];
    removeHeaders = {
      type = "RequestHeaderModifier";
      requestHeaderModifier.remove = identityHeaders;
    };
    navidrome = {
      name = "navidrome";
      inherit port;
    };
    viaProxy = {
      name = "oauth2-proxy";
      namespace = "identity";
      port = 4180;
    };
  in {
    gatus.endpoints.navidrome = {
      url = "https://${hostname}/ping";
      group = "internal";
      conditions = ["[STATUS] == 200"];
    };
    applications.navidrome = {
      namespace = "media";
      generatedSecrets.navidrome-admin = {
        key = "password";
        bitwarden = "navidrome/admin-password";
      };
      # Idempotent post-sync bootstrap (apps/app-bootstrap navidrome, >= 0.6.0): first admin
      # named after tristan, so the oauth2-proxy-forwarded username IS the admin. The generated
      # password is for Subsonic clients and break-glass native login.
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-navidrome; "${repository}:${tag}@${digest}";
        args = ["navidrome"];
        env = {
          NAVIDROME_URL = "http://navidrome.media.svc.cluster.local:${toString port}";
          ADMIN_USER = people.me;
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
        };
        secrets.admin = "navidrome-admin";
      };
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
            # Trusted-header login, only reachable via oauth2-proxy: the route below strips
            # the header from every direct (Subsonic/share) request, and the whitelist is
            # pod IPs only. Pre-bootstrap there is no whitelist, so header auth is off.
          }
          // lib.optionalAttrs bootstrapped {
            ND_REVERSEPROXYUSERHEADER = userHeader;
            ND_REVERSEPROXYWHITELIST = "10.0.0.0/8";
          }
          // {
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
            rules =
              if bootstrapped
              then [
                # Subsonic API (mobile clients can't do OIDC), public shares and the heartbeat
                # go straight to Navidrome with auth headers stripped: they authenticate by
                # their own credentials, never by the trusted header.
                {
                  matches = map (path: {path = {type = "PathPrefix"; value = path;};}) ["/rest" "/share" "/ping"];
                  filters = [removeHeaders];
                  backendRefs = [navidrome];
                }
                {
                  filters = [removeHeaders];
                  backendRefs = [viaProxy];
                }
              ]
              else [{backendRefs = [viaProxy];}];
          };
        };
      };
    };
    # Always registered: the router needs the host, and the ReferenceGrant for `media`.
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://navidrome.media.svc.cluster.local:${toString port}";
      namespace = "media";
    };
  };
}
