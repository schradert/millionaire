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
    hostname = "romm.${domain}";
    # Metadata providers that need your own key (docs/manual-steps.md, "Game metadata keys"): list the
    # ones whose Bitwarden keys exist. Without any, RomM matches by filename and hash through
    # Hasheous and takes covers from Libretro (no key); IGDB/ScreenScraper/... add descriptions,
    # ratings and richer artwork.
    providers = [];
    providerKeys = {
      igdb = {
        IGDB_CLIENT_ID = "romm/igdb/client-id";
        IGDB_CLIENT_SECRET = "romm/igdb/client-secret";
      };
      screenscraper = {
        SCREENSCRAPER_USER = "romm/screenscraper/user";
        SCREENSCRAPER_PASSWORD = "romm/screenscraper/password";
      };
      steamgriddb.STEAMGRIDDB_API_KEY = "romm/steamgriddb/api-key";
      retroachievements.RETROACHIEVEMENTS_API_KEY = "romm/retroachievements/api-key";
    };
    store = name: {
      sourceRef.storeRef.name = name;
      sourceRef.storeRef.kind = "ClusterSecretStore";
    };
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/api/heartbeat";
      spec.httpGet.port = 8080;
    };
  in {
    gatus.endpoints.romm = {
      url = "https://${hostname}/api/heartbeat";
      group = "internal";
    };
    portal.apps.romm = {
      title = "RomM";
      icon = "romm";
      description = "Game library";
    };
    # Native OIDC, no oauth2-proxy: the clients (Argosy, Tender, Grout) call the API directly. RomM
    # reads roles from the `groups` claim on every login (admin from group admin; everyone else is a
    # plain user) and links a login to the existing user by verified email, so tristan lands on the
    # bootstrapped admin. Callback path is fixed by RomM.
    applications.keycloak.resources.keycloakClients.romm.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "romm";
        create = true;
      };
      definition = {
        clientId = "romm";
        name = "RomM";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/api/oauth/openid"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.romm = {
      namespace = "media";
      postgres.enable = true;
      volsync.pvcs.romm-assets.title = "romm-assets";
      volsync.pvcs.romm-resources.title = "romm-resources";
      generatedSecrets.romm-admin = {
        key = "password";
        bitwarden = "romm/admin-password";
      };
      generatedSecrets.romm-auth = {
        key = "ROMM_AUTH_SECRET_KEY";
        length = 64;
        bitwarden = "romm/auth-secret-key";
      };

      helm.releases.romm = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.romm = {
            # RWO volumes: a rolling update deadlocks on Multi-Attach.
            strategy = "Recreate";
            annotations."reloader.stakater.com/auto" = "true";
            pod.securityContext = {
              runAsUser = 1000;
              runAsGroup = 1000;
              fsGroup = 1000;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.romm = {
              image = pinned.images.romm;
              envFrom = [
                {configMapRef.name = "romm";}
                {secretRef.name = "romm";}
                {secretRef.name = "romm-auth";}
              ];
              probes.liveness.enabled = true;
              probes.readiness = probe {};
              probes.startup = probe {
                spec.failureThreshold = 60;
                spec.periodSeconds = 10;
              };
              resources.requests = {
                cpu = "100m";
                memory = "512Mi";
              };
              resources.limits.memory = "3Gi";
            };
          };
          service.romm.ports.http.port = 8080;

          configMaps.romm.data = {
            ROMM_BASE_URL = "https://${hostname}";
            ROMM_SESSION_SECURE_COOKIE = "true";
            ROMM_DB_DRIVER = "postgresql";
            DB_HOST = "romm-rw";
            DB_PORT = "5432";
            DB_NAME = "romm";
            DB_USER = "romm";
            REDIS_HOST = "romm-dragonfly";
            WEB_SERVER_CONCURRENCY = "2";
            # Titles land in the library from outside RomM (inotify does not see another pod's writes
            # on CephFS), so rescan nightly; the bootstrap queues the first scan.
            ENABLE_SCHEDULED_RESCAN = "true";
            SCHEDULED_RESCAN_CRON = "0 3 * * *";
            HASHEOUS_API_ENABLED = "true";
            OIDC_ENABLED = "true";
            OIDC_PROVIDER = "keycloak";
            OIDC_CLIENT_ID = "romm";
            OIDC_REDIRECT_URI = "https://${hostname}/api/oauth/openid";
            OIDC_SERVER_APPLICATION_URL = "https://keycloak.${domain}/realms/default";
            OIDC_CLAIM_ROLES = "groups";
            OIDC_ROLE_ADMIN = "admin";
            OIDC_ROLE_VIEWER = "*";
          };

          persistence.assets = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "5Gi";
            advancedMounts.romm.romm = [{path = "/romm/assets";}];
          };
          persistence.resources = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "10Gi";
            advancedMounts.romm.romm = [{path = "/romm/resources";}];
          };
          persistence.config = {
            type = "configMap";
            name = "romm-config";
            advancedMounts.romm.romm = [
              {
                path = "/romm/config/config.yml";
                subPath = "config.yml";
                readOnly = true;
              }
            ];
          };
          # The library stays as docs/games.md lays it out (console folders, names the pins depend on);
          # only the roms/ tree is mounted. BIOS is not: RomM wants bios/<platform>/<file>, ours has a
          # directory per BIOS.
          persistence.library = {
            type = "persistentVolumeClaim";
            existingClaim = "media-games";
            advancedMounts.romm.romm = [
              {
                path = "/romm/library/roms";
                subPath = "roms";
                readOnly = true;
              }
            ];
          };

          route.romm = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "romm";
                port = 8080;
              };
            };
          };
        };
      };

      # Console folders RomM does not know by name: the library keeps the pin names (PS1, DS, XB).
      resources.configMaps.romm-config.data."config.yml" = builtins.toJSON {
        system.platforms = {
          ds = "nds";
          ps1 = "psx";
          xb = "xbox";
        };
      };

      resources.dragonflies.romm-dragonfly.spec = {
        replicas = 1;
        args = ["--proactor_threads" "2"];
        resources.requests.memory = "256Mi";
        resources.limits.memory = "1Gi";
      };

      resources.externalSecrets.romm.spec.data =
        [
          ({
              secretKey = "DB_PASSWD";
              remoteRef.key = "romm-app";
              remoteRef.property = "password";
            }
            // store "kubernetes-media")
          ({
              secretKey = "OIDC_CLIENT_SECRET";
              remoteRef.key = "romm";
              remoteRef.property = "client-secret";
            }
            // store "kubernetes-identity")
        ]
        ++ lib.concatMap (p:
          lib.mapAttrsToList (env: key:
            {
              secretKey = env;
              remoteRef.key = key;
            }
            // store "bitwarden")
          providerKeys.${p})
        providers;

      # Idempotent post-sync bootstrap (apps/app-bootstrap romm, >= 0.45.0): the admin tristan with the
      # profile email (the Keycloak login links to it), tristan's client token for Tender and the other
      # clients (Secret romm-tristan-client-token, pushed to Bitwarden romm/tristan/client-token) and
      # the first library scan.
      bootstrap = {
        image = with pinned.images.app-bootstrap-romm; "${repository}:${tag}@${digest}";
        args = ["romm"];
        env = {
          ROMM_URL = "http://romm.media.svc.cluster.local:8080";
          ADMIN_USER = people.me;
          ADMIN_EMAIL = people.my.profiles.personal.email;
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
          CLIENT_TOKEN_SECRET = "romm-tristan-client-token";
        };
        secrets.admin = "romm-admin";
        rules = [
          {
            apiGroups = [""];
            resources = ["secrets"];
            verbs = ["create"];
          }
          {
            apiGroups = [""];
            resources = ["secrets"];
            resourceNames = ["romm-tristan-client-token"];
            verbs = ["get" "patch"];
          }
        ];
      };
      resources.pushSecrets.romm-tristan-client-token.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "romm-tristan-client-token";
        data = lib.toList {
          match = {
            secretKey = "token";
            remoteRef.remoteKey = "romm/tristan/client-token";
          };
        };
      };
    };
  };
}
