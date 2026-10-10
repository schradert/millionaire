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
    hostname = "autobrr.${domain}";
  in {
    gatus.endpoints.autobrr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Native OIDC, no oauth2-proxy. autobrr is single-user and does not link OIDC
    # logins to a local user: any realm user who completes the login gets a full
    # session (username from preferred_username). Scopes are fixed to
    # openid/profile/email, so there is no groups mapping. Enabling OIDC disables
    # the onboarding API, so the local break-glass user is created by the init
    # container below instead. Callback path fixed by autobrr (v1.74.0).
    applications.keycloak.resources.keycloakClients.autobrr.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "autobrr";
        create = true;
      };
      definition = {
        clientId = "autobrr";
        name = "autobrr";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/api/auth/oidc/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.autobrr = {
      namespace = "media";
      generatedSecrets.autobrr-admin = {
        key = "password";
        bitwarden = "autobrr/admin-password";
      };
      postgres.enable = true;
      volsync.pvcs.autobrr.title = "autobrr";
      helm.releases.autobrr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.autobrr = {
            annotations."reloader.stakater.com/auto" = "true";
            # Image runs as 1000; the volume mounts root-owned.
            pod.securityContext = {
              fsGroup = 1000;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            # Idempotent break-glass user: `autobrrctl change-password` succeeds only
            # for an existing user (and re-syncs the generated password); otherwise
            # create it. Runs before the app so the DB is migrated by autobrrctl itself.
            initContainers.bootstrap = {
              image = pinned.images.autobrr;
              command = ["/bin/sh" "-ec"];
              args = [
                ''
                  pw=$(cat /admin/password)
                  i=0
                  while :; do
                    rc=0
                    out=$(printf '%s\n' "$pw" | autobrrctl --config /config change-password "$ADMIN_USER" 2>&1) || rc=$?
                    if [ "$rc" = 0 ]; then echo "user $ADMIN_USER present"; exit 0; fi
                    case "$out" in
                      *"failed to get user"*)
                        printf '%s\n' "$pw" | autobrrctl --config /config create-user "$ADMIN_USER"
                        echo "user $ADMIN_USER created"; exit 0 ;;
                    esac
                    i=$((i + 1))
                    if [ "$i" -ge 60 ]; then echo "bootstrap failed: $out" >&2; exit 1; fi
                    sleep 5
                  done
                ''
              ];
              env = {
                ADMIN_USER = people.me;
                AUTOBRR__POSTGRES_USER = "autobrr";
                AUTOBRR__POSTGRES_PASSWORD_FILE = "/secrets/db_password.txt";
                AUTOBRR__POSTGRES_HOST = "autobrr-rw.media.svc.cluster.local";
                AUTOBRR__POSTGRES_PORT = "5432";
                AUTOBRR__POSTGRES_DATABASE = "autobrr";
                AUTOBRR__DATABASE_TYPE = "postgres";
              };
            };
            containers.autobrr = {
              image = pinned.images.autobrr;
              envFrom = [{configMapRef.name = "autobrr";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.autobrr.ports.http.port = 7474;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
          };
          persistence.secrets = {
            type = "secret";
            name = "autobrr";
            globalMounts = lib.toList {
              path = "/secrets";
              readOnly = true;
            };
          };
          persistence.admin = {
            type = "secret";
            name = "autobrr-admin";
            globalMounts = lib.toList {
              path = "/admin";
              readOnly = true;
            };
          };
          persistence.tmpfs = {
            type = "emptyDir";
            globalMounts = [
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
          configMaps.autobrr.data = {
            AUTOBRR__CHECK_FOR_UPDATES = "false";
            AUTOBRR__HOST = "0.0.0.0";
            AUTOBRR__LOG_LEVEL = "INFO";
            AUTOBRR__SESSION_SECRET_FILE = "/secrets/session_secret.txt";
            AUTOBRR__DATABASE_TYPE = "postgres";
            AUTOBRR__POSTGRES_USER = "autobrr";
            AUTOBRR__POSTGRES_PASSWORD_FILE = "/secrets/db_password.txt";
            # Explicit FQDN + port: with the short name the app dialed the
            # `autobrr` Service IP on :5432 and hung until the startup probe killed it.
            AUTOBRR__POSTGRES_HOST = "autobrr-rw.media.svc.cluster.local";
            AUTOBRR__POSTGRES_PORT = "5432";
            AUTOBRR__POSTGRES_DATABASE = "autobrr";
            AUTOBRR__OIDC_ENABLED = "true";
            AUTOBRR__OIDC_ISSUER = "https://keycloak.${domain}/realms/default";
            AUTOBRR__OIDC_CLIENT_ID = "autobrr";
            AUTOBRR__OIDC_CLIENT_SECRET_FILE = "/secrets/oidc_client_secret.txt";
            AUTOBRR__OIDC_REDIRECT_URL = "https://${hostname}/api/auth/oidc/callback";
            # Local login stays on (break-glass).
            AUTOBRR__OIDC_DISABLE_BUILT_IN_LOGIN = "false";
          };
          route.autobrr = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "autobrr";
                port = 7474;
              };
            };
          };
        };
      };
      # Random once, never refreshed: the app persists it as its own key.
      resources.passwords.autobrr-apikey.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = true;
        allowRepeat = true;
      };
      resources.externalSecrets.autobrr-apikey.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "autobrr-apikey";
          };
          rewrite = lib.toList {
            regexp = {
              source = "password";
              target = "apikey";
            };
          };
        };
      };
      resources.externalSecrets.autobrr.spec.data = [
        {
          secretKey = "session_secret.txt";
          remoteRef.key = "autobrr-apikey";
          remoteRef.property = "apikey";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "db_password.txt";
          remoteRef.key = "autobrr-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "oidc_client_secret.txt";
          remoteRef.key = "autobrr";
          remoteRef.property = "client-secret";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
  };
}
