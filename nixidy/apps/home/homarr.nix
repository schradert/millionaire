# Homarr 2.x portal: Keycloak OIDC (groups claim -> Homarr groups of the same
# name; Keycloak `admin` is the Homarr admin group), Postgres via CNPG.
# Boards live in the database, so the bootstrap Job (apps/app-bootstrap
# homarr) onboards, keeps a credentials break-glass admin, and syncs the
# portal.apps catalog into the app library and the `homelab` board.
# Visibility is per board (admin + family view), not per tile.
{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "homarr.${domain}";
in {
  nixidy = {
    config,
    lib,
    pinned,
    ...
  }: let
    bootstrapped = pinned.images ? app-bootstrap-homarr;
  in {
    gatus.endpoints.homarr = {
      url = "https://${hostname}/api/health/live";
      group = "internal";
    };
    portal.apps.homarr = {
      title = "Homarr";
      description = "Portal";
    };
    applications.keycloak.resources.keycloakClients.homarr.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "homarr";
        create = true;
      };
      definition = {
        clientId = "homarr";
        name = "Homarr";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/api/auth/callback/oidc"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.homarr = {
      namespace = "home";
      postgres.enable = true;
      generatedSecrets = {
        # SECRET_ENCRYPTION_KEY: 64 hex chars (digits only are valid hex).
        homarr-db-encryption = {
          key = "db-encryption-key";
          length = 64;
          numeric = true;
          bitwarden = "homarr/db-encryption-key";
        };
        homarr-admin = {
          key = "password";
          upper = true;
          bitwarden = "homarr/admin-password";
        };
      };
      helm.releases.homarr = {
        chart = pinned.charts.homarr;
        values = {
          image = with pinned.images.homarr; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          env = {
            TZ = "America/Los_Angeles";
            # credentials: the bootstrap's break-glass admin.
            AUTH_PROVIDERS = "oidc,credentials";
            AUTH_OIDC_ISSUER = "https://keycloak.${domain}/realms/default";
            AUTH_OIDC_CLIENT_NAME = "Keycloak";
            AUTH_OIDC_AUTO_LOGIN = "true";
            AUTH_OIDC_SCOPE_OVERWRITE = "openid email profile groups";
            AUTH_OIDC_GROUPS_ATTRIBUTE = "groups";
          };
          # The 1s probe timeout trips whenever dingo (control plane + etcd) is
          # loaded, and the liveness failure SIGTERMs a healthy app (12 restarts).
          livenessProbe = {
            initialDelaySeconds = 30;
            timeoutSeconds = 5;
            failureThreshold = 6;
          };
          readinessProbe = {
            initialDelaySeconds = 30;
            timeoutSeconds = 5;
          };
          resources = {
            requests = {
              cpu = "100m";
              memory = "512Mi";
            };
            limits.memory = "1Gi";
          };
          database.type = "postgresql";
          envSecrets = {
            authOidcCredentials = {
              existingSecret = "homarr-oidc";
              oidcClientId = "client_id";
              oidcClientSecret = "client_secret";
            };
            dbCredentials = {
              existingSecret = "homarr-app";
              dbUrlKey = "uri";
            };
            dbEncryption = {
              existingSecret = "homarr-db-encryption";
              key = "db-encryption-key";
            };
          };
        };
      };
      resources.externalSecrets.homarr-oidc.spec = {
        target.template.data = {
          client_id = "homarr";
          client_secret = "{{ .client_secret }}";
        };
        data = lib.toList {
          secretKey = "client_secret";
          remoteRef.key = "homarr";
          remoteRef.property = "client-secret";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
      };
      resources.httpRoutes.homarr.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "homarr";
            port = 7575;
          };
        };
      };
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-homarr; "${repository}:${tag}@${digest}";
        args = ["homarr"];
        env = {
          # The public URL: sign-in cookies are Secure.
          HOMARR_URL = "https://${hostname}";
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
          ADMIN_GROUP = "admin";
          VIEW_GROUPS = "family";
          CATALOG_JSON = config.portal.files."catalog.json";
        };
        secrets.admin = "homarr-admin";
      };
    };
  };
}
