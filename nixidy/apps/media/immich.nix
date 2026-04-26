{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "immich.${domain}";
    serverProbe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec = {
        httpGet.path = "/api/server/ping";
        httpGet.port = "http";
        initialDelaySeconds = 0;
        periodSeconds = 10;
        timeoutSeconds = 1;
        failureThreshold = 3;
      };
    };
    mlProbe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec = {
        httpGet.path = "/ping";
        httpGet.port = "http";
        initialDelaySeconds = 0;
        periodSeconds = 10;
        timeoutSeconds = 1;
        failureThreshold = 3;
      };
    };
  in {
    gatus.endpoints.immich = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Immich supports native OIDC — configured via the admin UI pointing at this client.
    applications.keycloak.resources.keycloakClients.immich.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "immich";
        create = true;
      };
      definition = {
        clientId = "immich";
        name = "Immich";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = [
          "https://${hostname}/auth/login"
          "https://${hostname}/user-settings"
          "app.immich:///oauth-callback"
        ];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };
    applications.immich = {
      namespace = "media";
      postgres = {
        enable = true;
        extensions = ["vectors" "cube" "earthdistance"];
      };
      volsync.pvcs = {
        immich-server.title = "immich-server";
        immich-machine-learning.title = "immich-machine-learning";
      };

      helm.releases.immich-server = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.immich-server = {
            strategy = "RollingUpdate";
            annotations."reloader.stakater.com/auto" = "true";
            containers.immich-server = {
              image.repository = "ghcr.io/immich-app/immich-server";
              image.tag = "v2.6.1";
              image.digest = "sha256:aa7fe8eec3130742d07498dac7e02baa2d32a903573810ba95ed11f155c7eac1";
              envFrom = [{configMapRef.name = "immich-server";}];
              probes.liveness = serverProbe {};
              probes.readiness = serverProbe {};
              probes.startup = serverProbe {spec.failureThreshold = 30;};
            };
          };
          service.immich-server.ports.http = {
            primary = true;
            port = 2283;
          };
          persistence.config = {
            type = "configMap";
            name = "immich-server-files";
          };
          persistence.secrets = {
            type = "secret";
            name = "immich-server";
          };
          persistence.library = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            advancedMounts.immich-server.immich-server = [{path = "/usr/src/app/upload";}];
          };
          configMaps.immich-server-files.data."immich.json" = builtins.toJSON {};
          configMaps.immich-server.data = {
            IMMICH_CONFIG_FILE = "/config/immich.json";
            DB_HOSTNAME = "immich-rw.media.svc.cluster.local";
            DB_USERNAME = "immich";
            DB_PASSWORD_FILE = "/secrets/db_password.txt";
            REDIS_HOSTNAME = "immich-dragonfly.media.svc.cluster.local";
          };
          route.immich-server = {
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
        };
      };

      helm.releases.immich-machine-learning = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.immich-machine-learning = {
            strategy = "RollingUpdate";
            annotations."reloader.stakater.com/auto" = "true";
            containers.immich-machine-learning = {
              image.repository = "ghcr.io/immich-app/immich-machine-learning";
              image.tag = "v2.6.1";
              image.digest = "sha256:cafc1ff51b95a931d17d69226435bbb28ea314f151598b8b087391c232d00ab6";
              probes.liveness = mlProbe {};
              probes.readiness = mlProbe {};
              probes.startup = mlProbe {spec.failureThreshold = 60;};
            };
          };
          persistence.cache = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "10Gi";
          };
          service.immich-machine-learning.ports.http.port = 3003;
        };
      };

      resources.dragonflies.immich-dragonfly.spec = {
        replicas = 1;
        resources.requests.memory = "256Mi";
        resources.limits.memory = "512Mi";
      };

      resources.externalSecrets.immich-server.spec.data = [
        {
          secretKey = "db_password.txt";
          remoteRef.key = "immich-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://immich-server.media.svc.cluster.local:2283";
      namespace = "media";
    };
  };
}
