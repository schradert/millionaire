{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "sure.${domain}";
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/up";
      spec.httpGet.port = "http";
    };
    envFrom = [
      {configMapRef.name = "sure";}
      {secretRef.name = "sure";}
    ];
  in {
    applications.keycloak.resources.keycloakClients.sure.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "sure";
        create = true;
      };
      definition = {
        clientId = "sure";
        name = "Sure Finance";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/auth/oidc/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    gatus.endpoints.sure = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.sure = {
      namespace = "finance";
      postgres.enable = true;
      postgres.database = "sure_production";
      volsync.pvcs.sure.title = "sure";

      helm.releases.sure = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.sure = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.sure = {
              image.repository = "ghcr.io/we-promise/sure";
              image.tag = "stable";
              # TODO: pin digest for reproducibility
              inherit envFrom;
              ports = lib.toList {
                name = "http";
                containerPort = 3000;
              };
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

          controllers.sure-worker = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.sure-worker = {
              image.repository = "ghcr.io/we-promise/sure";
              image.tag = "stable";
              args = ["bundle" "exec" "sidekiq"];
              inherit envFrom;
              probes.liveness.enabled = false;
              probes.readiness.enabled = false;
              probes.startup.enabled = false;
            };
          };

          service.sure = {
            controller = "sure";
            ports.http.port = 3000;
          };

          configMaps.sure.data = {
            SELF_HOSTED = "true";
            RAILS_ENV = "production";
            RAILS_ASSUME_SSL = "true";
            DB_HOST = "sure-rw";
            DB_PORT = "5432";
            POSTGRES_USER = "sure";
            REDIS_URL = "redis://sure-dragonfly.finance.svc.cluster.local:6379/0";
            ONBOARDING_STATE = "invite_only";
            APP_DOMAIN = hostname;
            OIDC_ISSUER = "https://keycloak.${domain}/realms/default";
            OIDC_REDIRECT_URI = "https://${hostname}/auth/oidc/callback";
          };

          persistence.storage = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "5Gi";
            advancedMounts.sure.sure = [{path = "/rails/storage";}];
          };
        };
      };
      resources.httpRoutes.sure.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "sure";
            port = 3000;
          };
        };
      };

      # DragonflyDB instance for Redis (Sidekiq queue + caching)
      resources.dragonflies.sure-dragonfly.spec = {
        replicas = 1;
        args = ["--proactor_threads" "2"];
        resources.requests.memory = "256Mi";
        resources.limits.memory = "1Gi";
      };

      resources.externalSecrets.sure.spec.data = [
        {
          secretKey = "SECRET_KEY_BASE";
          remoteRef.key = "sure/secret_key_base";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "POSTGRES_PASSWORD";
          remoteRef.key = "sure-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-finance";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "OIDC_CLIENT_ID";
          remoteRef.key = "sure";
          remoteRef.property = "client-id";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "OIDC_CLIENT_SECRET";
          remoteRef.key = "sure";
          remoteRef.property = "client-secret";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
  };
}
