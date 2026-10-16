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
    hostname = "immich.${domain}";
    # app-bootstrap >= 0.18.0 mints tristan's API key (bootstrap below).
    apiKey = lib.versionAtLeast pinned.images.app-bootstrap-immich.tag "0.18.0";
    # app-bootstrap >= 0.19.7 also makes the e2e harness's admin and its API key.
    e2eAdmin = lib.versionAtLeast pinned.images.app-bootstrap-immich.tag "0.19.7";
    # Probes use numeric ports: app-template doesn't declare a named container port.
    serverProbe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec = {
        httpGet.path = "/api/server/ping";
        httpGet.port = 2283;
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
        httpGet.port = 3003;
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
    # Immich native OIDC: wired up in IMMICH_CONFIG_FILE (immich-config Secret below).
    # Logins link to an existing user by email (tristan -> the bootstrapped admin).
    # New users get admin from immich_role, which the Keycloak `admin` group sets.
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
        defaultClientScopes = ["openid" "profile" "email" "groups"];
        protocolMappers = lib.toList {
          name = "immich_role";
          protocol = "openid-connect";
          protocolMapper = "oidc-usermodel-attribute-mapper";
          consentRequired = false;
          config = {
            "user.attribute" = "immich_role";
            "claim.name" = "immich_role";
            "jsonType.label" = "String";
            # Pick it up from the user's groups (KeycloakGroup admin).
            "aggregate.attrs" = "true";
            "multivalued" = "false";
            "id.token.claim" = "true";
            "access.token.claim" = "true";
            "userinfo.token.claim" = "true";
            "introspection.token.claim" = "true";
          };
        };
      };
    };
    applications.immich = {
      namespace = "media";
      postgres = {
        enable = true;
        instances = 2;
        # immich v2.x needs VectorChord; the stock CNPG operand image ships
        # neither vchord nor the legacy pgvecto.rs "vectors" extension, so
        # bootstrap would die on CREATE EXTENSION. Use immich's purpose-built
        # operand image (bundles VectorChord + pgvecto.rs compat).
        # "vector" must precede "vchord" (dependency; no CASCADE emitted).
        image = with pinned.images.immich-postgres; "${repository}:${tag}@${digest}";
        # That image's postgres user is 999, not CNPG's default 26 (initdb dies
        # with "could not look up effective user ID 26").
        uid = 999;
        gid = 999;
        extensions = ["vector" "vchord" "cube" "earthdistance"];
        sharedPreloadLibraries = ["vchord.so"];
        # immich's operand image lacks the barman-cloud tools, so archiving failed
        # ("barman-cloud-check-wal-archive: executable file not found") and WAL piled up
        # on the 5Gi PVC. The DB relies on immich's built-in dump job (default 02:00)
        # into the immich-server PVC, which VolSync backs up (unverified). Re-enable with a CNPG-based
        # vectorchord image or the barman-cloud plugin.
        backup.enable = false;
      };
      volsync.pvcs = {
        immich-server.title = "immich-server";
        immich-machine-learning.title = "immich-machine-learning";
      };

      helm.releases.immich-server = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.immich-server = {
            # RWO volume: a rolling update deadlocks on Multi-Attach.
            strategy = "Recreate";
            annotations."reloader.stakater.com/auto" = "true";
            containers.immich-server = {
              image = pinned.images.immich-server;
              envFrom = [{configMapRef.name = "immich-server";}];
              probes.liveness = serverProbe {};
              probes.readiness = serverProbe {};
              probes.startup = serverProbe {spec.failureThreshold = 30;};
            };
          };
          service.immich-server.ports = {
            http = {
              primary = true;
              port = 2283;
            };
            # IMMICH_TELEMETRY_INCLUDE below: API and job workers each serve /metrics.
            api-metrics.port = 8081;
            worker-metrics.port = 8082;
          };
          serviceMonitor.immich-server = {
            serviceName = "immich-server";
            endpoints = [
              {
                port = "api-metrics";
                path = "/metrics";
                interval = "1m";
              }
              {
                port = "worker-metrics";
                path = "/metrics";
                interval = "1m";
              }
            ];
          };
          # immich.json (oauth + break-glass password login) rendered by ESO so the
          # client secret never lands in a ConfigMap.
          persistence.config = {
            type = "secret";
            name = "immich-config";
          };
          persistence.secrets = {
            type = "secret";
            name = "immich-db-password";
          };
          persistence.library = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "200Gi";
            advancedMounts.immich-server.immich-server = [{path = "/usr/src/app/upload";}];
          };
          configMaps.immich-server.data = {
            IMMICH_CONFIG_FILE = "/config/immich.json";
            IMMICH_TELEMETRY_INCLUDE = "all";
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
              # Native OIDC, no oauth2-proxy: the mobile app needs the API directly.
              backendRefs = lib.toList {
                name = "immich-server";
                port = 2283;
              };
            };
          };
        };
      };

      helm.releases.immich-machine-learning = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.immich-machine-learning = {
            # RWO volume: a rolling update deadlocks on Multi-Attach.
            strategy = "Recreate";
            annotations."reloader.stakater.com/auto" = "true";
            containers.immich-machine-learning = {
              image = pinned.images.immich-machine-learning;
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
        # Dragonfly sizes itself to the node's cores (32 here) and refuses to
        # start without 256MiB per thread.
        #
        # Immich's BullMQ queues run Lua scripts that touch keys they did not declare; Dragonfly
        # refuses that by default ("script tried accessing undeclared key", every background job
        # failed to enqueue: uploads answered 500, the version check never ran).
        args = ["--proactor_threads" "2" "--default_lua_flags=allow-undeclared-keys"];
        resources.requests.memory = "512Mi";
        resources.limits.memory = "1Gi";
      };

      resources.externalSecrets.immich-config.spec = {
        data = lib.toList {
          secretKey = "client_secret";
          remoteRef.key = "immich";
          remoteRef.property = "client-secret";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
        target.template.data."immich.json" = builtins.toJSON {
          server.externalDomain = "https://${hostname}";
          # Break-glass: the generated admin password (Bitwarden immich/admin-password).
          passwordLogin.enabled = true;
          oauth = {
            enabled = true;
            issuerUrl = "https://keycloak.${domain}/realms/default";
            clientId = "immich";
            clientSecret = "{{ .client_secret }}";
            scope = "openid email profile";
            buttonText = "Login with Keycloak";
            autoRegister = true;
            autoLaunch = false;
            roleClaim = "immich_role";
          };
        };
      };

      # Admin password: random once, never refreshed (CreatedOnce), pushed to
      # Bitwarden so the human can read it. Consumed by the bootstrap job.
      resources.passwords.immich-admin.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.immich-admin.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "immich-admin";
          };
        };
      };
      resources.pushSecrets.immich-admin.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "immich-admin";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "immich/admin-password";
          };
        };
      };
      # Idempotent post-sync bootstrap: first admin via /api/auth/admin-sign-up if
      # the server is uninitialized, then checks login and that OAuth is live
      # (apps/app-bootstrap). Reruns after every sync, so it must stay a no-op.
      # Image: `image publish app-bootstrap` (modules/images.nix) -> Harbor.
      # From 0.18.0 it also mints the admin's (= tristan's, linked by email) API key for
      # immich-cli into immich-tristan-api-key, pushed to Bitwarden immich/tristan/api-key.
      bootstrap = {
        image = with pinned.images.app-bootstrap-immich; "${repository}:${tag}@${digest}";
        args = ["immich"];
        env =
          {
            IMMICH_URL = "http://immich-server.media.svc.cluster.local:2283";
            ADMIN_EMAIL = people.my.profiles.personal.email;
            ADMIN_PASSWORD_FILE = "/secrets/admin/password";
            REQUIRE_OAUTH = "1";
          }
          // lib.optionalAttrs apiKey {API_KEY_SECRET = "immich-tristan-api-key";}
          // lib.optionalAttrs e2eAdmin {
            # A second admin for the e2e harness (apps/e2e identity/oidc-immich), which needs one to
            # delete the user a test login creates; its API key goes to immich-e2e-api-key.
            E2E_API_KEY_SECRET = "immich-e2e-api-key";
            E2E_EMAIL = "e2e@e2e.${domain}";
          };
        secrets.admin = "immich-admin";
        rules = lib.optionals apiKey [
          {
            apiGroups = [""];
            resources = ["secrets"];
            verbs = ["create"];
          }
          {
            apiGroups = [""];
            resources = ["secrets"];
            resourceNames = ["immich-tristan-api-key"] ++ lib.optional e2eAdmin "immich-e2e-api-key";
            verbs = ["get" "patch"];
          }
        ];
      };
      resources.pushSecrets.immich-tristan-api-key = lib.mkIf apiKey {
        spec = {
          secretStoreRefs = lib.toList {
            name = "bitwarden";
            kind = "ClusterSecretStore";
          };
          selector.secret.name = "immich-tristan-api-key";
          data = lib.toList {
            match = {
              secretKey = "api-key";
              remoteRef.remoteKey = "immich/tristan/api-key";
            };
          };
        };
      };

      # Not "immich-server": CNPG owns a Secret of that name (the cluster's
      # server TLS cert), so ESO could never take ownership of it.
      resources.externalSecrets.immich-db-password.spec.data = [
        {
          secretKey = "db_password.txt";
          remoteRef.key = "immich-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
  };
}
