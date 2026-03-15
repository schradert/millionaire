{config, ...}: {
  # TODO https://docs.firefly-iii.org/how-to/data-importer/how-to-configure/
  # TODO https://github.com/dvankley/firefly-plaid-connector-2
  # TODO create access token at firefly/token
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "firefly.${domain}";
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/health";
      spec.httpGet.port = "http";
    };
  in {
    applications.firefly = {
      namespace = "finance";
      postgres.enable = true;
      helm.releases.firefly = {
        chart = charts.bjw-s-labs.app-template;
        values = {
          controllers.firefly = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.firefly = {
              image.repository = "fireflyiii/core";
              image.tag = "version-6.5.4";
              image.digest = "sha256:6ae1b92eb73b4ae8a8e7e038440b93fba46267e05b5b903c62316b8cb03779af";
              probes.liveness = probe {};
              probes.readiness = probe {
                spec.initialDelaySeconds = 15;
                spec.timeoutSeconds = 1;
              };
              probes.startup = probe {
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };
          service.firefly.ports.http.port = 8080;
          configMaps.firefly.data = {
            AUTHENTICATION_GUARD = "remote_user_guard";
            AUTHENTICATION_GUARD_HEADER = "HTTP_X_AUTH_REQUEST_PREFERRED_USERNAME";
            AUTHENTICATION_GUARD_EMAIL = "HTTP_X_AUTH_REQUEST_EMAIL";
            APP_KEY_FILE = "/secrets/app_key.txt";
            DB_CONNECTION = "pgsql";
            DB_HOST = "firefly-rw";
            DB_PORT = "5432";
            DB_DATABASE = "firefly";
            DB_USERNAME = "firefly";
            DB_PASSWORD_FILE = "/secrets/db_password.txt";
          };
          persistence = {
            secrets = {
              type = "secret";
              name = "firefly";
            };
            upload = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
              globalMounts = [{path = "/var/www/html/storage/upload";}];
            };
            config = {
              type = "configMap";
              name = "firefly";
              globalMounts = lib.toList {
                path = "/.env";
                readOnly = true;
              };
            };
          };
          route.firefly = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
      helm.releases.firefly-importer = {
        chart = charts.bjw-s-labs.app-template;
        values = {
          controllers.firefly-importer = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.firefly-importer = {
              image.repository = "fireflyiii/data-importer";
              image.tag = "version-2.2.1";
              image.digest = "sha256:98cb3aa6dbd6681cbdc590a5d70dd7d964b637bac863d947bcbc20448ac56b8a";
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.firefly-importer.ports.http.port = 8080;
          configMaps.firefly-importer.data = {
            IGNORE_DUPLICATE_ERRORS = "false";
            FIREFLY_III_URL = "http" + "://firefly.dotfiles.svc.cluster.local";
            VANITY_URL = "https" + "://${hostname}";
          };
          persistence = {
            secrets = {
              type = "secret";
              name = "firefly-importer";
            };
            config = {
              type = "configMap";
              name = "firefly-importer";
              globalMounts = lib.toList {
                path = "/.env";
                readOnly = true;
              };
            };
          };
          route.firefly-importer = {
            hostnames = ["firefly-importer-${config.canivete.meta.people.me}.${domain}"];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
      resources.externalSecrets = {
        firefly.spec.data = [
          {
            secretKey = "app_key.txt";
            remoteRef.key = "firefly/admin/password";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "db_password.txt";
            remoteRef.key = "firefly-app";
            remoteRef.property = "password";
            sourceRef.storeRef.name = "kubernetes-finance";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
        firefly-importer.spec.data = lib.toList {
          secretKey = "app_token.txt";
          remoteRef.key = "firefly/token";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
      };
    };
  };
}
