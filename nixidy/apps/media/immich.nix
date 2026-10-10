{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "immich.${domain}";
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
        # immich v2.x needs VectorChord; the stock CNPG operand image ships
        # neither vchord nor the legacy pgvecto.rs "vectors" extension, so
        # bootstrap would die on CREATE EXTENSION. Use immich's purpose-built
        # operand image (bundles VectorChord + pgvecto.rs compat).
        # "vector" must precede "vchord" (dependency; no CASCADE emitted).
        image = "ghcr.io/immich-app/postgres:17-vectorchord0.4.3-pgvectors0.3.0";
        # That image's postgres user is 999, not CNPG's default 26 (initdb dies
        # with "could not look up effective user ID 26").
        uid = 999;
        gid = 999;
        extensions = ["vector" "vchord" "cube" "earthdistance"];
        sharedPreloadLibraries = ["vchord.so"];
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

      # Photo library: never let a sync or app removal delete it.
      resources.persistentVolumeClaims.immich-server.metadata.annotations."argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";

      resources.dragonflies.immich-dragonfly.spec = {
        replicas = 1;
        # Dragonfly sizes itself to the node's cores (32 here) and refuses to
        # start without 256MiB per thread.
        args = ["--proactor_threads" "2"];
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
      resources.jobs.immich-bootstrap = {
        metadata.annotations = {
          "argocd.argoproj.io/hook" = "PostSync";
          "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
        };
        spec = {
          backoffLimit = 6;
          activeDeadlineSeconds = 1200;
          template.spec = {
            restartPolicy = "OnFailure";
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = lib.toList {
              name = "bootstrap";
              image = "harbor.${domain}/library/app-bootstrap:0.1.0";
              args = ["immich"];
              env = [
                {
                  name = "IMMICH_URL";
                  value = "http://immich-server.media.svc.cluster.local:2283";
                }
                {
                  name = "ADMIN_EMAIL";
                  value = people.my.profiles.personal.email;
                }
                {
                  name = "ADMIN_PASSWORD_FILE";
                  value = "/secrets/admin/password";
                }
                {
                  name = "REQUIRE_OAUTH";
                  value = "1";
                }
              ];
              volumeMounts = lib.toList {
                name = "admin";
                mountPath = "/secrets/admin";
                readOnly = true;
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = ["ALL"];
              };
            };
            volumes = lib.toList {
              name = "admin";
              secret.secretName = "immich-admin";
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
