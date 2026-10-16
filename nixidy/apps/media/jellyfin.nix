{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "jellyfin.${domain}";
    # Jellyfin Trakt plugin (scrobbles plays to trakt.tv). Linking a Jellyfin user to Trakt is a
    # device-code login in the plugin's page (docs/manual-steps.md "Ryot: Trakt and Letterboxd").
    traktPlugin = false;
    # Server settings applied by the bootstrap (jellyfin-bootstrap >= 0.7.0), drift-checked on every sync.
    # Every request arrives through the gateway, so Jellyfin sees pod addresses, never the client's: with
    # a cap set, every client that is not on a subnet below (i.e. every one) counts as remote.
    # Cap for remote clients, Mbps (0 = none).
    remoteBitrateMbps = 8;
    # Networks Jellyfin treats as local; everything else (the tailnet 100.64.0.0/10 included) is remote.
    localNetworkSubnets = ["192.168.50.0/24"];
    # Codecs falcon's NVDEC decodes (the A2000 encodes h264 and hevc, not av1).
    hardwareDecodingCodecs = ["h264" "hevc" "vp9" "av1"];
    # Per-user policy: lets Jellyfin and Findroid apps download media for offline use.
    enableContentDownloading = true;
    # Bump to rotate Maintainerr's Jellyfin API key: the bootstrap makes `Maintainerr (gen N)`, points
    # Maintainerr at it, then deletes the older ones.
    maintainerrKeyGeneration = 2;
  in {
    gatus.endpoints.jellyfin = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302)"];
    };
    # Keycloak OIDC client for the jellyfin-plugin-sso (installed and configured by the
    # jellyfin-bootstrap job; the route stays direct, no oauth2-proxy).
    applications.keycloak.resources.keycloakClients.jellyfin.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "jellyfin";
        create = true;
      };
      definition = {
        clientId = "jellyfin";
        name = "Jellyfin";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/sso/OID/redirect/keycloak"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.jellyfin = {
      namespace = "media";
      volsync.pvcs.jellyfin.title = "jellyfin-config";
      helm.releases.jellyfin = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.jellyfin = {
            annotations."reloader.stakater.com/auto" = "true";
            # Transcodes on falcon's GPU (NVENC/NVDEC): on the nvidia runtime without a device request,
            # so the card stays shared with the desktop, dvdrip and tdarr. Pending while falcon is down.
            pod = {
              runtimeClassName = "nvidia";
              nodeSelector."nvidia.com/gpu.present" = "true";
              tolerations = lib.toList {
                key = "node.trdos.me/class";
                operator = "Equal";
                value = "desktop";
                effect = "PreferNoSchedule";
              };
            };
            # /metrics is off until system.xml says EnableMetrics (no env or flag for it).
            # Skipped on first boot, when Jellyfin has not written the file yet.
            initContainers.metrics = {
              image = pinned.images.jellyfin;
              command = [
                "sh"
                "-c"
                "f=/config/config/system.xml; [ -f $f ] && sed -i 's|<EnableMetrics>false</EnableMetrics>|<EnableMetrics>true</EnableMetrics>|' $f || true"
              ];
            };
            containers.jellyfin = {
              image = pinned.images.jellyfin;
              resources.requests = {
                cpu = "285m";
                memory = "560Mi";
              };
              env = {
                NVIDIA_VISIBLE_DEVICES = "all";
                NVIDIA_DRIVER_CAPABILITIES = "compute,video,utility";
              };
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              # Plugins and libraries have made first start take over 30s; the default (3 x 10s) killed it in a loop.
              probes.startup = {
                enabled = true;
                spec.failureThreshold = 60;
              };
            };
          };
          service.jellyfin.ports.http.port = 8096;
          serviceMonitor.jellyfin = {
            serviceName = "jellyfin";
            endpoints = lib.toList {
              port = "http";
              path = "/metrics";
              interval = "1m";
            };
          };
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              # jellyfin 10.11 refuses to start unless its data path (/config)
              # has >=2GiB free (StorageHelper startup check) — 1Gi gave only
              # 957MiB free and crashed even with no media. 5Gi clears it + DB room.
              size = "5Gi";
            };
            cache = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
              globalMounts = [{path = "/config/metadata";}];
            };
            tmpfs = {
              type = "emptyDir";
              globalMounts = [
                {
                  path = "/cache";
                  subPath = "cache";
                }
                {
                  path = "/config/log";
                  subPath = "log";
                }
                {
                  path = "/tmp";
                  subPath = "tmp";
                }
              ];
            };
            media-movies = {
              type = "persistentVolumeClaim";
              existingClaim = "media-movies";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/movies";
                  readOnly = true;
                }
              ];
            };
            media-dvd = {
              type = "persistentVolumeClaim";
              existingClaim = "media-dvd";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/dvd";
                  readOnly = true;
                }
              ];
            };
            media-tv = {
              type = "persistentVolumeClaim";
              existingClaim = "media-tv";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/tv";
                  readOnly = true;
                }
              ];
            };
            media-music = {
              type = "persistentVolumeClaim";
              existingClaim = "media-music";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/music";
                  readOnly = true;
                }
              ];
            };
            media-books = {
              type = "persistentVolumeClaim";
              existingClaim = "media-books";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/books";
                  readOnly = true;
                }
              ];
            };
            media-audiobooks = {
              type = "persistentVolumeClaim";
              existingClaim = "media-audiobooks";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/audiobooks";
                  readOnly = true;
                }
              ];
            };
            media-comics = {
              type = "persistentVolumeClaim";
              existingClaim = "media-comics";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/comics";
                  readOnly = true;
                }
              ];
            };
            media-sports = {
              type = "persistentVolumeClaim";
              existingClaim = "media-sports";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/sports";
                  readOnly = true;
                }
              ];
            };
            # Not a library: media-e2e's test libraries live under /media/downloads/e2e-<run>,
            # outside every real library and not hidden (Jellyfin skips dot-folders).
            media-downloads = {
              type = "persistentVolumeClaim";
              existingClaim = "media-downloads";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/downloads";
                  readOnly = true;
                }
              ];
            };
          };
          route.jellyfin = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
      # Admin password: random once, never refreshed (CreatedOnce), then pushed to
      # Bitwarden so the human can log in. Consumed by the bootstrap job.
      resources.passwords.jellyfin-admin.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.jellyfin-admin.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "jellyfin-admin";
          };
        };
      };
      resources.pushSecrets.jellyfin-admin.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "jellyfin-admin";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "jellyfin/admin-password";
          };
        };
      };
      resources.externalSecrets.jellyfin-oidc.spec.data = lib.toList {
        secretKey = "client_secret";
        remoteRef.key = "jellyfin";
        remoteRef.property = "client-secret";
        sourceRef.storeRef.name = "kubernetes-identity";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
      # Idempotent post-sync bootstrap: runs the startup wizard if needed, creates
      # the admin user, any missing libraries, Maintainerr's Jellyfin connection (and its key rotation),
      # the Keycloak SSO plugin + provider + login button and the server settings above
      # (apps/jellyfin-bootstrap). Reruns after every sync, so it must stay a no-op once everything exists.
      # Image: `image publish jellyfin-bootstrap` (modules/images.nix) -> Harbor. The `bootstrap`
      # option (nixidy/system/cicd/bootstrap.nix) hashes the spec into a tracked ConfigMap, so a new
      # pin or env reruns it.
      bootstrap = {
        image = with pinned.images.jellyfin-bootstrap; "${repository}:${tag}@${digest}";
        env = {
          JELLYFIN_URL = "http://jellyfin.media.svc.cluster.local:8096";
          MAINTAINERR_URL = "http://maintainerr.media.svc.cluster.local:6246";
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
          SSO_ISSUER = "https://keycloak.${domain}/realms/default";
          SSO_SECRET_FILE = "/secrets/oidc/client_secret";
          MAINTAINERR_KEY_GENERATION = toString maintainerrKeyGeneration;
          ENCODING_HW_ACCEL = "nvenc";
          ENCODING_DECODING_CODECS = lib.concatStringsSep "," hardwareDecodingCodecs;
          ENCODING_TONEMAPPING = "true";
          REMOTE_BITRATE_LIMIT = toString (remoteBitrateMbps * 1000000);
          LOCAL_NETWORK_SUBNETS = lib.concatStringsSep "," localNetworkSubnets;
          ENABLE_CONTENT_DOWNLOADING = lib.boolToString enableContentDownloading;
          # Stable-repository plugins (name|guid|version, jellyfin-bootstrap >= 0.4.0). TMDb Box Sets
          # groups movies into their franchise collections (the Jellyfin-native stand-in for Kometa,
          # which only drives Plex); Webhook carries plays to Ryot (its destination is written by
          # Ryot's bootstrap); Trakt scrobbles when `traktPlugin`.
          PLUGINS = lib.concatStringsSep "," (
            [
              "TMDb Box Sets|bc4aad2e-d3d0-4725-a5e2-fd07949e5b42|13.0.0.0"
              "Webhook|71552a5a5c5c4350a2aeebe451a30173|21.0.0.0"
              # Third-party repositories (a fourth field, jellyfin-bootstrap >= 0.6.0). Smart Lists:
              # rule-based collections and playlists that refresh themselves (genre, decade, studio,
              # rating, recently added). Intro Skipper: detects intros and credits and adds Skip.
              # SmartLists 12.0.1.0 is the last build for 10.11; Intro Skipper's manifest is served
              # per Jellyfin version.
              "SmartLists|A0A2A7B2-747A-4113-8B39-757A9D267C79|12.0.1.0|https://raw.githubusercontent.com/jyourstone/jellyfin-plugin-manifest/main/manifest.json"
              "Intro Skipper|c83d86bb-a1e0-4c35-a113-e2101cf4ee6b|1.10.11.24|https://intro-skipper.org/manifest.json"
            ]
            ++ lib.optional traktPlugin "Trakt|4fe3201ed6ae4f2e8917e12bda571281|30.0.0.0"
          );
        };
        secrets = {
          admin = "jellyfin-admin";
          oidc = "jellyfin-oidc";
        };
      };
    };
    # Playback metrics (sessions, direct play vs transcode, bitrate) for the media-data-flow
    # dashboard; Jellyfin's own /metrics has none. The exporter only takes an API key, so an
    # init container signs in as admin, finds or creates the key `jellyfin-exporter` and
    # hands it over in an emptyDir: no secret to create by hand.
    applications.jellyfin-exporter = {
      namespace = "media";
      helm.releases.jellyfin-exporter = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.jellyfin-exporter = {
            pod.securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              fsGroup = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            initContainers.token = {
              image = pinned.images.curl;
              command = [
                "sh"
                "-c"
                ''
                  set -eu
                  base=http://jellyfin.media.svc.cluster.local:8096
                  name=jellyfin-exporter
                  auth='MediaBrowser Client="jellyfin-exporter", Device="exporter", DeviceId="jellyfin-exporter", Version="1"'
                  pw=$(cat /secrets/admin/password)
                  tok=$(curl -fsS -H "X-Emby-Authorization: $auth" -H 'Content-Type: application/json' \
                    -d "{\"Username\":\"admin\",\"Pw\":\"$pw\"}" "$base/Users/AuthenticateByName" \
                    | grep -o '"AccessToken":"[^"]*"' | head -1 | cut -d'"' -f4)
                  authed="X-Emby-Authorization: $auth, Token=\"$tok\""
                  lookup() {
                    curl -fsS -H "$authed" "$base/Auth/Keys" | tr '{' '\n' | grep "\"AppName\":\"$name\"" \
                      | grep -o '"AccessToken":"[^"]*"' | head -1 | cut -d'"' -f4
                  }
                  key=$(lookup || true)
                  if [ -z "$key" ]; then
                    curl -fsS -X POST -H "$authed" "$base/Auth/Keys?app=$name"
                    key=$(lookup)
                  fi
                  curl -fsS -X POST -H "$authed" "$base/Sessions/Logout" || true
                  [ -n "$key" ]
                  printf %s "$key" > /key/token
                ''
              ];
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = ["ALL"];
              };
            };
            containers.jellyfin-exporter = {
              image = pinned.images.jellyfin-exporter;
              env.JELLYFIN_ADDRESS = "http://jellyfin.media.svc.cluster.local:8096";
              command = [
                "sh"
                "-c"
                "read -r t < /key/token; exec /bin/jellyfin_exporter --jellyfin.token=\"$t\" --collector.transcoding"
              ];
              ports = lib.toList {
                name = "metrics";
                containerPort = 9594;
              };
              probes = let
                port = {
                  enabled = true;
                  custom = true;
                  spec.tcpSocket.port = "metrics";
                };
              in {
                liveness = port;
                readiness = port;
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = ["ALL"];
              };
            };
          };
          service.jellyfin-exporter.ports.metrics.port = 9594;
          serviceMonitor.jellyfin-exporter = {
            serviceName = "jellyfin-exporter";
            endpoints = lib.toList {
              port = "metrics";
              path = "/metrics";
              interval = "30s";
            };
          };
          persistence = {
            admin-secret = {
              type = "secret";
              name = "jellyfin-admin";
              advancedMounts.jellyfin-exporter.token = [{path = "/secrets/admin";}];
            };
            key = {
              type = "emptyDir";
              advancedMounts.jellyfin-exporter = {
                token = [{path = "/key";}];
                jellyfin-exporter = [{path = "/key";}];
              };
            };
          };
        };
      };
    };
  };
}
