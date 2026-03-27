{config, ...}: {
  # TODO AI features https://docs.mealie.io/documentation/getting-started/installation/open-ai/
  # TODO bulk import some recipes https://docs.mealie.io/documentation/community-guide/bulk-url-import/
  # TODO bookmarklet https://docs.mealie.io/documentation/community-guide/import-recipe-bookmarklet/
  # TODO theme dracula / stylix
  # TODO ollama api key + model
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "mealie.${domain}";
  in {
    gatus.endpoints.mealie = { url = "https://${hostname}"; group = "internal"; };

    # Keycloak OIDC client — Hostzero operator syncs secret to K8s
    applications.keycloak.resources.keycloakClients.mealie.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "mealie";
        name = "Mealie";
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/login*"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    applications.mealie = {
      namespace = "health";
      postgres.enable = true;
      helm.releases.mealie = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.mealie = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.mealie = {
              image.repository = "ghcr.io/mealie-recipes/mealie";
              image.tag = "v3.0.1";
              image.digest = "sha256:4d7542becc4f5a2a87c13f1073c974430006f56207278ade541bd93450b8fb5f";
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
            ALLOW_PASSWORD_LOGIN = "False";
            DB_ENGINE = "postgres";
            POSTGRES_SERVER = "mealie-rw";
            POSTGRES_PASSWORD_FILE = "/secrets/db_password.txt";
            OIDC_AUTH_ENABLED = "True";
            OIDC_CONFIGURATION_URL = "https://keycloak.${domain}/realms/default/.well-known/openid-configuration";
            OIDC_CLIENT_ID = "mealie";
            OIDC_CLIENT_SECRET_FILE = "/secrets/client_secret";
            OIDC_PROVIDER_NAME = "Keycloak";
            OIDC_SIGNUP_ENABLED = "True";
            OIDC_USER_GROUP = "/family";
            OIDC_ADMIN_GROUP = "/admin";
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
          remoteRef.property = "CLIENT_SECRET";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
  };
}
