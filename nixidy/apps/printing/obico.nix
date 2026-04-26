{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "obico.${domain}";
  in {
    gatus.endpoints.obico = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.obico = {
      namespace = "printing";
      postgres.enable = true;
      volsync.pvcs.obico.title = "obico";
      helm.releases.obico = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.web = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.web = {
              image.repository = "thespaghettidetective/web";
              image.tag = "latest";
              env = {
                DEBUG = "False";
                SITE_USES_HTTPS = "True";
                SITE_IS_QA = "False";
                REDIS_URL = "redis://obico-redis:6379";
                DATABASE_URL = "postgres://obico:$(DB_PASSWORD)@obico-rw:5432/obico";
                INTERNAL_MEDIA_HOST = "http://obico-web:3334";
                ML_API_HOST = "http://obico-ml:3333";
                ACCOUNT_ALLOW_SIGN_UP = "False";
              };
              envFrom = lib.toList {secretRef.name = "obico";};
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          controllers.ml = {
            containers.ml = {
              image.repository = "thespaghettidetective/ml_api";
              image.tag = "latest";
              env.ML_API_TOKEN = "$(ML_API_TOKEN)";
              envFrom = lib.toList {secretRef.name = "obico";};
            };
          };
          controllers.redis = {
            containers.redis = {
              image.repository = "ghcr.io/dragonflydb/dragonfly";
              image.tag = "v1.25.5";
              args = ["--maxmemory" "256mb"];
            };
          };
          service.obico-web.controller = "web";
          service.obico-web.ports.http.port = 3334;
          service.obico-ml.controller = "ml";
          service.obico-ml.ports.http.port = 3333;
          service.obico-redis.controller = "redis";
          service.obico-redis.ports.redis.port = 6379;
          persistence.media = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "10Gi";
            advancedMounts.web.web = lib.toList {path = "/app/static_build/media";};
          };
        };
      };

      resources.httpRoutes.obico.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "oauth2-proxy";
            namespace = "identity";
            port = 4180;
          };
        };
      };

      resources.externalSecrets.obico.spec.data = [
        {
          secretKey = "DB_PASSWORD";
          remoteRef.key = "obico-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-printing";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "ML_API_TOKEN";
          remoteRef.key = "printing/obico/ml-api-token";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "SECRET_KEY";
          remoteRef.key = "printing/obico/secret-key";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://obico-web.printing.svc.cluster.local:3334";
      namespace = "printing";
    };
  };
}
