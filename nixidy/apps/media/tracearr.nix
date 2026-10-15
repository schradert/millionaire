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
    hostname = "tracearr.${domain}";
    port = 3000;
    uid = 1001;
    db = "tracearr-db.media.svc.cluster.local";
    # Plain pg_isready, no password: the superuser comes from the image's local trust rule.
    pgProbe = {
      enabled = true;
      custom = true;
      spec.exec.command = ["pg_isready" "-U" "tracearr" "-d" "tracearr"];
    };
    appProbe = {
      enabled = true;
      custom = true;
      spec.httpGet = {
        path = "/health";
        inherit port;
      };
    };
    fromMediaStore = secretKey: key: property: {
      inherit secretKey;
      remoteRef = {inherit key property;};
      sourceRef.storeRef.name = "kubernetes-media";
      sourceRef.storeRef.kind = "ClusterSecretStore";
    };
  in {
    gatus.endpoints.tracearr = {
      url = "https://${hostname}/health";
      group = "internal";
      conditions = ["[STATUS] == 200"];
    };
    # Native OIDC (OIDC_* env below). The owner is the account the bootstrap creates with
    # tristan's email, so logging in as tristan *is* the owner; family members sign in as the
    # account Tracearr synced from their own Jellyfin user (matched by email / username), with
    # no rights beyond their own data.
    applications.keycloak.resources.keycloakClients.tracearr.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "tracearr";
        create = true;
      };
      definition = {
        clientId = "tracearr";
        name = "Tracearr";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/api/v1/auth/oauth2/callback/oidc"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };
    applications.tracearr = {
      namespace = "media";
      # Tracearr's own scheduled dumps land in the backup volume, which VolSync backs up (the
      # TimescaleDB volume is not: a file-level copy of a live database is not a backup).
      volsync.pvcs.tracearr-backup.title = "tracearr-backup";
      # Idempotent post-sync bootstrap (apps/app-bootstrap tracearr, >= 0.24.0): the owner (tristan, his email, so his
      # Keycloak login links to it), the Jellyfin server with an API key named Tracearr, member sign-in and a daily backup.
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-tracearr) {
        image = with pinned.images.app-bootstrap-tracearr; "${repository}:${tag}@${digest}";
        args = ["tracearr"];
        env = {
          ADMIN_USER = people.me;
          ADMIN_EMAIL = people.my.profiles.personal.email;
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
          CLAIM_CODE_FILE = "/secrets/claim/code";
          JELLYFIN_ADMIN_PASSWORD_FILE = "/secrets/jellyfin/password";
          JELLYFIN_PUBLIC_URL = "https://jellyfin.${domain}";
          TRACEARR_EXTERNAL_URL = "https://${hostname}";
        };
        secrets = {
          admin = "tracearr-admin";
          claim = "tracearr-claim";
          jellyfin = "jellyfin-admin";
        };
      };
      generatedSecrets = {
        tracearr-db.key = "password";
        tracearr-jwt.key = "secret";
        tracearr-cookie.key = "secret";
        tracearr-auth.key = "secret";
        # First-time setup claim code: until the owner exists, creating one (password or OIDC) needs it,
        # so nobody can claim an unbootstrapped instance. The bootstrap passes it.
        tracearr-claim.key = "code";
        # Owner break-glass login (Bitwarden tracearr/admin-password).
        tracearr-admin = {
          key = "password";
          upper = true;
          bitwarden = "tracearr/admin-password";
        };
      };
      resources.externalSecrets.tracearr.spec = {
        data = [
          (fromMediaStore "db" "tracearr-db" "password")
          (fromMediaStore "jwt" "tracearr-jwt" "secret")
          (fromMediaStore "cookie" "tracearr-cookie" "secret")
          (fromMediaStore "auth" "tracearr-auth" "secret")
          (fromMediaStore "claim" "tracearr-claim" "code")
          {
            secretKey = "oidc";
            remoteRef.key = "tracearr";
            remoteRef.property = "client-secret";
            sourceRef.storeRef.name = "kubernetes-identity";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
        target.template.data = {
          DATABASE_URL = "postgres://tracearr:{{ .db }}@${db}:5432/tracearr";
          JWT_SECRET = "{{ .jwt }}";
          COOKIE_SECRET = "{{ .cookie }}";
          BETTER_AUTH_SECRET = "{{ .auth }}";
          OIDC_CLIENT_SECRET = "{{ .oidc }}";
          CLAIM_CODE = "{{ .claim }}";
        };
      };
      resources.externalSecrets.tracearr-postgres.spec = {
        data = [(fromMediaStore "password" "tracearr-db" "password")];
        target.template.data = {
          POSTGRES_USER = "tracearr";
          POSTGRES_DB = "tracearr";
          POSTGRES_PASSWORD = "{{ .password }}";
        };
      };
      # Redis for the job queues and sessions. Tracearr's BullMQ scripts touch keys they did not
      # declare, which Dragonfly refuses unless told otherwise (same as immich).
      resources.dragonflies.tracearr-dragonfly.spec = {
        replicas = 1;
        args = ["--proactor_threads" "1" "--default_lua_flags=allow-undeclared-keys"];
        resources.requests.memory = "256Mi";
        resources.limits.memory = "768Mi";
      };
      helm.releases.tracearr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.tracearr = {
            # Off until the bootstrap pin lands and carries the claim code: raise to 1 with it.
            replicas =
              if pinned.images ? app-bootstrap-tracearr
              then 1
              else 0;
            annotations."reloader.stakater.com/auto" = "true";
            # RWO backup volume: a rolling update deadlocks on Multi-Attach.
            strategy = "Recreate";
            pod.securityContext = {
              runAsUser = uid;
              runAsGroup = uid;
              fsGroup = uid;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.tracearr = {
              image = pinned.images.tracearr;
              envFrom = [{secretRef.name = "tracearr";} {configMapRef.name = "tracearr";}];
              probes = {
                liveness = appProbe;
                readiness = appProbe;
                startup = appProbe // {spec = appProbe.spec // {failureThreshold = 60;};};
              };
            };
          };
          # TimescaleDB (hypertables and continuous aggregates): not a stock CNPG operand image,
          # so a plain Deployment on its own volume, flags as in Tracearr's compose file.
          controllers.db = {
            strategy = "Recreate";
            annotations."reloader.stakater.com/auto" = "true";
            # The image's postgres user (1000) owns the data directory it initialises.
            pod.securityContext = {
              runAsUser = 1000;
              runAsGroup = 1000;
              fsGroup = 1000;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.db = {
              image = pinned.images.timescaledb;
              args = [
                "postgres"
                "-c"
                "timescaledb.license=timescale"
                "-c"
                "timescaledb.max_tuples_decompressed_per_dml_transaction=100000"
                "-c"
                "max_locks_per_transaction=4096"
                "-c"
                "timescaledb.telemetry_level=off"
                "-c"
                "max_connections=150"
              ];
              envFrom = [{secretRef.name = "tracearr-postgres";}];
              probes = {
                liveness = pgProbe;
                readiness = pgProbe;
                startup = pgProbe // {spec = pgProbe.spec // {failureThreshold = 60;};};
              };
              resources = {
                requests = {
                  cpu = "100m";
                  memory = "512Mi";
                };
                limits.memory = "2Gi";
              };
            };
          };
          service.tracearr = {
            controller = "tracearr";
            ports.http.port = port;
          };
          service.db = {
            controller = "db";
            ports.postgres.port = 5432;
          };
          persistence = {
            # Mounted one level above the data directory so initdb creates `data` itself
            # (it insists on owning the directory, which a volume root is not).
            db = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "20Gi";
              advancedMounts.db.db = [{path = "/home/postgres/pgdata";}];
            };
            shm = {
              type = "emptyDir";
              medium = "Memory";
              sizeLimit = "512Mi";
              advancedMounts.db.db = [{path = "/dev/shm";}];
            };
            backup = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "10Gi";
              advancedMounts.tracearr.tracearr = [{path = "/data/backup";}];
            };
            image-cache = {
              type = "emptyDir";
              advancedMounts.tracearr.tracearr = [{path = "/data/tracearr/image-cache";}];
            };
            tmpfs = {
              type = "emptyDir";
              advancedMounts.tracearr.tracearr = [
                {
                  path = "/tmp";
                  subPath = "tmp";
                }
              ];
            };
          };
          configMaps.tracearr.data = {
            NODE_ENV = "production";
            HOST = "0.0.0.0";
            PORT = toString port;
            LOG_LEVEL = "info";
            TZ = "UTC";
            REDIS_URL = "redis://tracearr-dragonfly.media.svc.cluster.local:6379";
            # Cilium's gateway is one trusted proxy hop; the session cookie then gets Secure.
            TRUST_PROXY = "true";
            CORS_ORIGIN = "https://${hostname}";
            OIDC_ISSUER_URL = "https://keycloak.${domain}/realms/default";
            OIDC_CLIENT_ID = "tracearr";
            OIDC_PROVIDER_NAME = "Keycloak";
          };
          # Direct route, no oauth2-proxy: Tracearr's own OIDC logs people in, and its mobile app
          # and API keys need the app itself.
          route.tracearr = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "tracearr";
                inherit port;
              };
            };
          };
        };
      };
    };
  };
}
