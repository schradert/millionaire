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
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
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
      # the admin user, any missing libraries, Maintainerr's Jellyfin connection and
      # the Keycloak SSO plugin + provider + login button (apps/jellyfin-bootstrap). Reruns
      # after every sync, so it must stay a no-op once everything exists.
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
          # Stable-repository plugins (name|guid|version, jellyfin-bootstrap >= 0.4.0). TMDb Box Sets
          # groups movies into their franchise collections (the Jellyfin-native stand-in for Kometa,
          # which only drives Plex); Webhook carries plays to Ryot (its destination is written by
          # Ryot's bootstrap); Trakt scrobbles when `traktPlugin`.
          PLUGINS = lib.concatStringsSep "," (
            [
              "TMDb Box Sets|bc4aad2e-d3d0-4725-a5e2-fd07949e5b42|13.0.0.0"
              "Webhook|71552a5a5c5c4350a2aeebe451a30173|21.0.0.0"
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
  };
}
