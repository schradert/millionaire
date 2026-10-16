{config, ...}: let
  inherit (config.canivete.meta) people;
  # Trakt history import (docs/manual-steps.md "Ryot: Trakt and Letterboxd"): a public Trakt
  # profile, imported once by the bootstrap and then followed by the `ryot-trakt` CronJob below.
  # Needs a Trakt API app's client id in Bitwarden `ryot/trakt/client-id` (Ryot's
  # SERVER_IMPORTER_TRAKT_CLIENT_ID).
  trakt = {
    enable = false;
    username = "";
  };
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "ryot.${domain}";
    # Ryot has no config-file path for OIDC users: an account is created (and linked by the
    # OIDC `sub`) on first OIDC login, and the first user on an empty instance becomes admin.
    # The bootstrap job (apps/app-bootstrap ryot, >= 0.14.0) pre-registers tristan as admin,
    # linked to his Keycloak `sub`, with the admin access token (which works with registration
    # closed). Until its image is pinned the instance stays open for that first login, behind
    # oauth2-proxy.
    bootstrapped = pinned.images ? app-bootstrap-ryot;
  in {
    gatus.endpoints.ryot = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Native OIDC: callback is FRONTEND_URL + /api/auth. Ryot only requests the
    # `email` scope and uses the email claim as the username; roles are NOT mapped
    # from claims (the bootstrap registers the admin up front).
    applications.keycloak.resources.keycloakClients.ryot.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "ryot";
        create = true;
      };
      definition = {
        clientId = "ryot";
        name = "Ryot";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/api/auth"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.ryot = {
      namespace = "media";
      postgres.enable = true;
      postgres.instances = 2;
      helm.releases.ryot = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.ryot = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.ryot = {
              image = pinned.images.ryot;
              envFrom = [{configMapRef.name = "ryot";} {secretRef.name = "ryot";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.ryot.ports.http.port = 8000;
          configMaps.ryot.data = {
            SERVER_INSECURE_COOKIE = "false";
            FRONTEND_URL = "https://${hostname}";
            FRONTEND_OIDC_BUTTON_LABEL = "Continue with Keycloak";
            SERVER_OIDC_CLIENT_ID = "ryot";
            SERVER_OIDC_ISSUER_URL = "https://keycloak.${domain}/realms/default";
            # Password login stays as break-glass. Admin-token calls to registerUser
            # still work with registration closed.
            USERS_ALLOW_REGISTRATION = lib.boolToString (!bootstrapped);
            VIDEO_GAMES_TWITCH_CLIENT_ID = "";
            VIDEO_GAMES_TWITCH_CLIENT_SECRET = "";
          };
          route.ryot = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList (
                if bootstrapped
                then {
                  name = "ryot";
                  port = 8000;
                }
                else {
                  name = "oauth2-proxy";
                  namespace = "identity";
                  port = 4180;
                }
              );
            };
          };
        };
      };
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-ryot; "${repository}:${tag}@${digest}";
        args = ["ryot"];
        # Also wires tristan's integrations (apps/app-bootstrap/src/ryot_wire.rs, >= 0.25.0): Jellyfin
        # sink + the Webhook plugin's destination, Audiobookshelf and Komga yank, Radarr/Sonarr push
        # from the "Request" collection, one-time Audiobookshelf (and Trakt) imports.
        env =
          {
            RYOT_URL = "http://ryot.media.svc.cluster.local:8000";
            OIDC_USERNAME = people.me;
            ADMIN_ACCESS_TOKEN_FILE = "/secrets/token/password";
            KEYCLOAK_PASSWORD_FILE = "/secrets/keycloak/password";
            RYOT_DB_PASSWORD_FILE = "/secrets/db/password";
            JELLYFIN_ADMIN_PASSWORD_FILE = "/secrets/jellyfin/password";
            AUDIOBOOKSHELF_PASSWORD_FILE = "/secrets/audiobookshelf/password";
            KOMGA_EMAIL = people.my.profiles.personal.email;
            KOMGA_PASSWORD_FILE = "/secrets/komga/password";
            RADARR_API_KEY_FILE = "/secrets/radarr/apikey";
            SONARR_API_KEY_FILE = "/secrets/sonarr/apikey";
            RADARR_PROFILE = "HD-1080p";
            SONARR_PROFILE = "WEB-1080p";
          }
          // lib.optionalAttrs trakt.enable {TRAKT_USERNAME = trakt.username;};
        secrets = {
          token = "ryot-admin-token";
          keycloak = "ryot-keycloak-admin";
          db = "ryot-app";
          jellyfin = "jellyfin-admin";
          audiobookshelf = "audiobookshelf-admin";
          komga = "komga-admin";
          radarr = "radarr-apikey";
          sonarr = "sonarr-apikey";
        };
      };
      # Keycloak master-realm admin, to resolve tristan's `sub` (same Bitwarden entry
      # as the keycloak app itself).
      resources.externalSecrets.ryot-keycloak-admin = lib.mkIf bootstrapped {
        spec.data = lib.toList {
          secretKey = "password";
          remoteRef.key = "keycloak/admin/password";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
      };
      # Random once, never refreshed: ryot refuses to start without an admin token.
      resources.passwords.ryot-admin-token.spec = {
        length = 40;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.ryot-admin-token.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "ryot-admin-token";
          };
        };
      };
      # Ryot follows Trakt (Trakt is the hub; Jellyfin's Trakt plugin and the streaming-service
      # scrobbler feed it). Ryot's Trakt import does not de-duplicate and cannot read only what is new, so
      # this reads the newest watch on the public profile, imports only when there is something newer (or
      # the last import is a week old, for ratings and lists) and removes what the import duplicated
      # (apps/app-bootstrap/src/ryot_trakt.rs, >= 0.39.0). It reads Ryot's database and acts as the user
      # through a one-use access link; the Trakt client id is the only secret it needs.
      resources.externalSecrets.ryot-trakt = lib.mkIf (bootstrapped && trakt.enable) {
        spec.data = lib.toList {
          secretKey = "client-id";
          remoteRef.key = "ryot/trakt/client-id";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
      };
      resources.cronJobs.ryot-trakt = lib.mkIf (bootstrapped && trakt.enable) {
        spec = let
          secretDirs = {
            trakt = "ryot-trakt";
            db = "ryot-app";
          };
        in {
          schedule = "17 * * * *";
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            backoffLimit = 0;
            # The import itself is given up to 30 minutes.
            activeDeadlineSeconds = 2400;
            ttlSecondsAfterFinished = 86400;
            template = {
              metadata.labels."app.kubernetes.io/name" = "ryot-trakt";
              spec = {
                restartPolicy = "Never";
                automountServiceAccountToken = false;
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = lib.toList {
                  name = "ryot-trakt";
                  image = with pinned.images.app-bootstrap-ryot; "${repository}:${tag}@${digest}";
                  args = ["ryot-trakt"];
                  env = lib.mapAttrsToList (name: value: {inherit name value;}) {
                    RYOT_URL = "http://ryot.media.svc.cluster.local:8000";
                    ADMIN_EMAIL = people.my.profiles.personal.email;
                    TRAKT_USERNAME = trakt.username;
                    TRAKT_CLIENT_ID_FILE = "/secrets/trakt/client-id";
                    RYOT_DB_PASSWORD_FILE = "/secrets/db/password";
                  };
                  volumeMounts =
                    [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                    ]
                    ++ lib.mapAttrsToList (dir: _: {
                      name = dir;
                      mountPath = "/secrets/${dir}";
                      readOnly = true;
                    })
                    secretDirs;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = ["ALL"];
                  };
                };
                volumes =
                  [
                    {
                      name = "tmp";
                      emptyDir = {};
                    }
                  ]
                  ++ lib.mapAttrsToList (dir: secretName: {
                    name = dir;
                    secret.secretName = secretName;
                  })
                  secretDirs;
              };
            };
          };
        };
      };
      resources.externalSecrets.ryot.spec.data =
        lib.optional trakt.enable {
          secretKey = "TRAKT_CLIENT_ID";
          remoteRef.key = "ryot/trakt/client-id";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        ++ [
          {
            secretKey = "DATABASE_URL";
            remoteRef.key = "ryot-app";
            remoteRef.property = "password";
            sourceRef.storeRef.name = "kubernetes-media";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "ADMIN_ACCESS_TOKEN";
            remoteRef.key = "ryot-admin-token";
            remoteRef.property = "password";
            sourceRef.storeRef.name = "kubernetes-media";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "OIDC_CLIENT_SECRET";
            remoteRef.key = "ryot";
            remoteRef.property = "client-secret";
            sourceRef.storeRef.name = "kubernetes-identity";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
      resources.externalSecrets.ryot.spec.target.template.data =
        {
          DATABASE_URL = "postgresql://ryot:{{ .DATABASE_URL }}@ryot-rw.media.svc.cluster.local:5432/ryot";
          SERVER_ADMIN_ACCESS_TOKEN = "{{ .ADMIN_ACCESS_TOKEN }}";
          SERVER_OIDC_CLIENT_SECRET = "{{ .OIDC_CLIENT_SECRET }}";
        }
        // lib.optionalAttrs trakt.enable {
          SERVER_IMPORTER_TRAKT_CLIENT_ID = "{{ .TRAKT_CLIENT_ID }}";
        };
    };
    oauth2Proxy.upstreams = lib.mkIf (!bootstrapped) {
      ${hostname} = {
        url = "http://ryot.media.svc.cluster.local:8000";
        namespace = "media";
      };
    };
  };
}
