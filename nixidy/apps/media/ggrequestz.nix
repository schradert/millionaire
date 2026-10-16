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
    hostname = "ggrequestz.${domain}";
    # Game search runs on IGDB. The app starts without keys but cannot search; the same Twitch
    # application serves RomM, so set this when Bitwarden holds `romm/igdb/{client-id,client-secret}`
    # (docs/manual-steps.md, "Game metadata keys").
    igdb = false;
    store = name: {
      sourceRef.storeRef.name = name;
      sourceRef.storeRef.kind = "ClusterSecretStore";
    };
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/api/health";
      spec.httpGet.port = 3000;
    };
  in {
    gatus.endpoints.ggrequestz = {
      url = "https://${hostname}/api/health";
      group = "internal";
    };
    portal.apps.ggrequestz = {
      title = "GG Requestz";
      icon = "mdi-gamepad-variant";
      description = "Game requests";
    };
    # Native OIDC, no oauth2-proxy. A login links to the bootstrapped admin row by email; the
    # `groups` claim sets roles on every login (group admin -> admin, everyone else a viewer).
    applications.keycloak.resources.keycloakClients.ggrequestz.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "ggrequestz";
        create = true;
      };
      definition = {
        clientId = "ggrequestz";
        name = "GG Requestz";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/api/auth/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.ggrequestz = {
      namespace = "media";
      postgres.enable = true;
      generatedSecrets.ggrequestz-session = {
        key = "SESSION_SECRET";
        length = 64;
      };

      helm.releases.ggrequestz = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.ggrequestz = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.ggrequestz = {
              image = pinned.images.ggrequestz;
              envFrom = [
                {configMapRef.name = "ggrequestz";}
                {secretRef.name = "ggrequestz";}
                {secretRef.name = "ggrequestz-session";}
              ];
              probes.liveness = probe {};
              probes.readiness = probe {};
              probes.startup = probe {
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
              resources.requests = {
                cpu = "50m";
                memory = "256Mi";
              };
              resources.limits.memory = "1Gi";
            };
          };
          service.ggrequestz.ports.http.port = 3000;

          configMaps.ggrequestz.data = {
            PUBLIC_SITE_URL = "https://${hostname}";
            ORIGIN = "https://${hostname}";
            POSTGRES_HOST = "ggrequestz-rw";
            POSTGRES_PORT = "5432";
            POSTGRES_DB = "ggrequestz";
            POSTGRES_USER = "ggrequestz";
            REDIS_URL = "redis://ggrequestz-dragonfly:6379";
            AUTH_METHOD = "oidc";
            OIDC_ISSUER_URL = "https://keycloak.${domain}/realms/default";
            OIDC_CLIENT_ID = "ggrequestz";
            OIDC_PROVIDER_NAME = "Keycloak";
            OIDC_REDIRECT_URI = "https://${hostname}/api/auth/callback";
            OIDC_SCOPES = "openid email profile groups";
            OIDC_ADMIN_GROUP = "admin";
            ROMM_SERVER_URL = "http://romm.media.svc.cluster.local:8080";
            ROMM_SERVER_URL_PUBLIC = "https://romm.${domain}";
            UPDATE_CHECK_ENABLED = "false";
          };

          route.ggrequestz = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "ggrequestz";
                port = 3000;
              };
            };
          };
        };
      };

      resources.dragonflies.ggrequestz-dragonfly.spec = {
        replicas = 1;
        args = ["--proactor_threads" "2"];
        resources.requests.memory = "256Mi";
        resources.limits.memory = "512Mi";
      };

      # RomM's client token for tristan, minted by the romm bootstrap (needs roms.read).
      resources.externalSecrets.ggrequestz.spec.data =
        [
          ({
              secretKey = "POSTGRES_PASSWORD";
              remoteRef.key = "ggrequestz-app";
              remoteRef.property = "password";
            }
            // store "kubernetes-media")
          ({
              secretKey = "OIDC_CLIENT_SECRET";
              remoteRef.key = "ggrequestz";
              remoteRef.property = "client-secret";
            }
            // store "kubernetes-identity")
          ({
              secretKey = "ROMM_API_TOKEN";
              remoteRef.key = "romm-tristan-client-token";
              remoteRef.property = "token";
            }
            // store "kubernetes-media")
        ]
        ++ lib.optionals igdb (lib.mapAttrsToList (env: key:
          {
            secretKey = env;
            remoteRef.key = key;
          }
          // store "bitwarden") {
          IGDB_CLIENT_ID = "romm/igdb/client-id";
          IGDB_CLIENT_SECRET = "romm/igdb/client-secret";
        });

      # Idempotent post-sync bootstrap (apps/app-bootstrap ggrequestz, >= 0.48.0): tristan's admin row,
      # so the first OIDC login is not whoever arrives first.
      bootstrap = {
        image = with pinned.images.app-bootstrap-ggrequestz; "${repository}:${tag}@${digest}";
        args = ["ggrequestz"];
        env = {
          ADMIN_EMAIL = people.my.profiles.personal.email;
          ADMIN_NAME = people.my.name;
          ADMIN_USER = people.me;
          GGREQUESTZ_DB_PASSWORD_FILE = "/secrets/db/password";
        };
        secrets.db = "ggrequestz-app";
      };
    };
  };
}
