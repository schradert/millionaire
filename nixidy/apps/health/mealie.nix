{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  # TODO AI features https://docs.mealie.io/documentation/getting-started/installation/ai-providers/
  # TODO bulk import some recipes https://docs.mealie.io/documentation/community-guide/bulk-url-import/
  # TODO bookmarklet https://docs.mealie.io/documentation/community-guide/import-recipe-bookmarklet/
  # TODO theme dracula / stylix
  # TODO ollama api key + model
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "mealie.${domain}";
    bootstrapped = pinned.images ? app-bootstrap-mealie;
  in {
    gatus.endpoints.mealie = {
      url = "https://${hostname}";
      group = "internal";
    };

    # Native OIDC (env-configured below), no oauth2-proxy. Logins are matched to a user
    # by the `email` claim (username, then email), and the `groups` claim (short names)
    # sets admin: `admin` -> admin, `family` -> plain user, anyone else is refused.
    # The bootstrap job renames the seeded admin to tristan's email, so tristan's
    # login IS that admin; password login stays on as break-glass (with
    # OIDC_AUTO_REDIRECT, reach the password form at /login?direct=1).
    # Keycloak OIDC client — Hostzero operator syncs secret to K8s
    applications.keycloak.resources.keycloakClients.mealie.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "mealie";
        create = true;
      };
      definition = {
        clientId = "mealie";
        name = "Mealie";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/login*"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };

    applications.mealie = {
      namespace = "health";
      generatedSecrets.mealie-admin = {
        key = "password";
        bitwarden = "mealie/admin-password";
      };
      # Idempotent post-sync bootstrap (apps/app-bootstrap mealie, >= 0.9.0): turns the
      # seeded changeme@example.com admin into tristan with the generated password.
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-mealie; "${repository}:${tag}@${digest}";
        args = ["mealie"];
        env = {
          MEALIE_URL = "http://mealie.health.svc.cluster.local:9000";
          ADMIN_USER = people.me;
          ADMIN_NAME = people.my.name;
          ADMIN_EMAIL = people.my.profiles.personal.email;
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
        };
        secrets.admin = "mealie-admin";
      };
      postgres.enable = true;
      helm.releases.mealie = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.mealie = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.mealie = {
              image = pinned.images.mealie;
              envFrom = [{configMapRef.name = "mealie";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.mealie.ports.http.port = 9000;
          persistence.secrets = {
            type = "secret";
            name = "mealie";
          };
          configMaps.mealie.data = {
            BASE_URL = "https://${hostname}";
            ALLOW_SIGNUP = "False";
            # Off until the bootstrap has replaced the seeded changeme@example.com /
            # MyPassword admin; then on as break-glass.
            ALLOW_PASSWORD_LOGIN =
              if bootstrapped
              then "True"
              else "False";
            DB_ENGINE = "postgres";
            POSTGRES_SERVER = "mealie-rw";
            POSTGRES_PASSWORD_FILE = "/secrets/db_password.txt";
            OIDC_AUTH_ENABLED = "True";
            OIDC_CONFIGURATION_URL = "https://keycloak.${domain}/realms/default/.well-known/openid-configuration";
            OIDC_CLIENT_ID = "mealie";
            OIDC_CLIENT_SECRET_FILE = "/secrets/client_secret";
            OIDC_PROVIDER_NAME = "Keycloak";
            OIDC_SIGNUP_ENABLED = "True";
            OIDC_USER_GROUP = "family";
            OIDC_ADMIN_GROUP = "admin";
            OIDC_AUTO_REDIRECT = "True";
            OIDC_REMEMBER_ME = "True";
            SMTP_HOST = "stalwart.mail.svc.cluster.local";
            SMTP_PORT = "25";
            SMTP_AUTH_STRATEGY = "NONE";
            SMTP_FROM_NAME = "Mealie";
            SMTP_FROM_EMAIL = "noreply@${domain}";
          };
        };
      };
      resources.httpRoutes.mealie.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "mealie";
            port = 9000;
          };
        };
      };
      resources.externalSecrets.mealie.spec.data = [
        {
          secretKey = "db_password.txt";
          remoteRef.key = "mealie-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-health";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "client_secret";
          remoteRef.key = "mealie";
          remoteRef.property = "client-secret";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
  };
}
