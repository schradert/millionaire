{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "keycloak.${domain}";
in {
  devenv = {...}: {
    scripts.keycloak-reset-password.exec = ''
      email="''${1:?Usage: keycloak-reset-password <email>}"
      realm="''${2:-default}"
      base_url="https://keycloak.${domain}"

      admin_password=$(kubectl get secret keycloak -n identity -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)

      token=$(curl -sf -X POST "$base_url/realms/master/protocol/openid-connect/token" \
        -d "client_id=admin-cli" \
        -d "grant_type=password" \
        -d "username=admin" \
        -d "password=$admin_password" | jq -r '.access_token')

      user_id=$(curl -sf -H "Authorization: Bearer $token" \
        "$base_url/admin/realms/$realm/users?email=$email&exact=true" | jq -r '.[0].id')

      if [ "$user_id" = "null" ] || [ -z "$user_id" ]; then
        echo "No user found with email: $email"
        exit 1
      fi

      curl -sf -X PUT -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '["UPDATE_PASSWORD"]' \
        "$base_url/admin/realms/$realm/users/$user_id/execute-actions-email"

      echo "Password reset email sent to $email"
    '';
  };
  nixidy = {
    charts,
    lib,
    ...
  }: {
    gatus.endpoints.keycloak = {
      url = "https://${hostname}";
      group = "internal";
    };
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
                KC_METRICS_ENABLED = "true";
                KC_FEATURES = "hostname:v2";
                KC_BOOTSTRAP_ADMIN_USERNAME = "admin";
              };
              envFrom = [{secretRef.name = "keycloak";}];
              ports = [
                {
                  name = "http";
                  containerPort = 8080;
                }
                {
                  name = "management";
                  containerPort = 9000;
                }
              ];
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health/live";
                spec.httpGet.port = "management";
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health/ready";
                spec.httpGet.port = "management";
              };
              probes.startup = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health/started";
                spec.httpGet.port = "management";
                spec.failureThreshold = 60;
                spec.periodSeconds = 10;
              };
            };
          };
          service.keycloak.ports = {
            http.port = 8080;
            management.port = 9000;
          };
          serviceMonitor.keycloak = {
            serviceName = "keycloak";
            endpoints = lib.toList {
              port = "management";
              scheme = "http";
              path = "/metrics";
              interval = "1m";
            };
          };
        };
      };
      resources = {
        # Keycloak needs to pass a valid FQDN to Stalwart for email sending
        # app-template doesn't support setting these variables though
        deployments.keycloak.spec.template.spec = {
          hostname = "keycloak";
          subdomain = "keycloak";
        };
        externalSecrets.keycloak.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.template.data = {
            KC_DB_PASSWORD = "{{ .db_password }}";
            KC_BOOTSTRAP_ADMIN_USERNAME = "admin";
            KC_BOOTSTRAP_ADMIN_PASSWORD = "{{ .admin_password }}";
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
