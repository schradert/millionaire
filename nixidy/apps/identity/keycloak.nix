{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "keycloak.${domain}";
in {
  nixidy = {charts, lib, ...}: {
    gatus.endpoints.keycloak = {url = "https://${hostname}"; group = "internal";};
    applications.keycloak = {
      namespace = "identity";
      postgres.enable = true;
      helm.releases.keycloak = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.keycloak = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.keycloak = {
              image.repository = "quay.io/keycloak/keycloak";
              image.tag = "26.1";
              args = ["start"];
              env = {
                KC_DB = "postgres";
                KC_DB_URL = "jdbc:postgresql://keycloak-rw:5432/keycloak";
                KC_DB_USERNAME = "keycloak";
                KC_HOSTNAME = hostname;
                KC_PROXY_HEADERS = "xforwarded";
                KC_HTTP_ENABLED = "true";
                KC_HEALTH_ENABLED = "true";
                KEYCLOAK_ADMIN = "admin";
              };
              envFrom = [{secretRef.name = "keycloak";}];
              ports = lib.toList {name = "http"; containerPort = 8080;};
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health/live";
                spec.httpGet.port = "http";
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health/ready";
                spec.httpGet.port = "http";
                spec.initialDelaySeconds = 30;
              };
              probes.startup = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health/started";
                spec.httpGet.port = "http";
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };
          service.keycloak.ports.http.port = 8080;
        };
      };
      resources = {
        externalSecrets.keycloak.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.template.data = {
            KC_DB_PASSWORD = "{{ .db_password }}";
            KEYCLOAK_ADMIN = "admin";
            KEYCLOAK_ADMIN_PASSWORD = "{{ .admin_password }}";
          };
          data = [
            {
              secretKey = "db_password";
              remoteRef.key = "keycloak-app";
              remoteRef.property = "password";
              sourceRef.storeRef.name = "kubernetes-identity";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
            {
              secretKey = "admin_password";
              remoteRef.key = "keycloak/admin/password";
              sourceRef.storeRef.name = "bitwarden";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
          ];
        };
        httpRoutes.keycloak.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "keycloak";
              port = 8080;
            };
          };
        };
      };
    };
  };
}
