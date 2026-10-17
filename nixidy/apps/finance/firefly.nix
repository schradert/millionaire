{config, ...}: {
  # TODO https://docs.firefly-iii.org/how-to/data-importer/how-to-configure/
  # TODO https://github.com/dvankley/firefly-plaid-connector-2
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "firefly.${domain}";
    # false: no ExternalSecret, RBAC or CronJob. true once Bitwarden holds `firefly/simplefin/token`
    # (docs/manual-steps.md, "Bank sync (SimpleFIN)"): imports the Bridge's accounts into Firefly daily.
    simplefin = true;
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/health";
      spec.httpGet.port = "http";
    };
  in {
    portal.apps.firefly = {
      title = "Firefly III";
      icon = "firefly-iii";
      description = "Personal finance manager";
    };
    gatus.endpoints.firefly = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.firefly = {
      namespace = "finance";
      postgres.enable = true;
      # sirver (failing root disk) hosts the lone instance today; keep a standby elsewhere.
      postgres.instances = 2;
      volsync.pvcs.firefly.title = "firefly";
      helm.releases.firefly = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.firefly = {
            annotations."reloader.stakater.com/auto" = "true";
            pod.securityContext.fsGroup = 33;
            containers.firefly = {
              image = pinned.images.firefly-core;
              resources.requests = {
                cpu = "80m";
                memory = "128Mi";
              };
              ports = lib.toList {
                name = "http";
                containerPort = 8080;
              };
              # Signing keys that survive restarts (the container's storage is not
              # persistent): PASSPORT_PRIVATE_KEY / PASSPORT_PUBLIC_KEY from the Secret
              # the firefly-bootstrap job writes. Optional: absent until its first run,
              # when Firefly falls back to its own keys.
              envFrom = lib.toList {
                secretRef = {
                  name = "firefly-passport";
                  optional = true;
                };
              };
              env = {
                # Behind the gateway TLS terminates upstream: without these Firefly sees http, its
                # <base href> is http:// (blocked as mixed content), and v1 pages load assets relative
                # to the page path (/accounts/v1/css/...) -> 404, unstyled pages.
                APP_URL = "https://${hostname}";
                TRUSTED_PROXIES = "**";
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
                SITE_OWNER = config.canivete.meta.people.my.profiles.personal.email;
                MAIL_MAILER = "smtp";
                MAIL_HOST = "stalwart.mail.svc.cluster.local";
                MAIL_PORT = "25";
                MAIL_ENCRYPTION = "null";
                MAIL_FROM = "noreply@${domain}";
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
          service.firefly.ports.http.port = 8080;
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
          };
        };
      };
      helm.releases.firefly-importer = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.firefly-importer = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.firefly-importer = {
              image = pinned.images.firefly-data-importer;
              resources.requests = {
                cpu = "50m";
                memory = "80Mi";
              };
              # Personal access token minted by the firefly-bootstrap job.
              env.FIREFLY_III_ACCESS_TOKEN_FILE = "/secrets/app_token.txt";
              # Container env, not the /.env below (Laravel never reads that path): the web importer logs
              # the tail of its access token at debug, the upstream default.
              env.LOG_LEVEL = "info";
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.firefly-importer.ports.http.port = 8080;
          configMaps.firefly-importer.data.".env" = lib.concatStringsSep "\n" [
            "IGNORE_DUPLICATE_ERRORS=false"
            "FIREFLY_III_URL=http://firefly.finance.svc.cluster.local:8080"
            "VANITY_URL=https://${hostname}"
          ];
          persistence = {
            # Only the token, not the signing keys that share the Secret. Projected into
            # /secrets (not a subPath): a stale live /secrets mount made the subPath fail.
            secrets = {
              type = "secret";
              name = "firefly-passport";
              items = lib.toList {
                key = "FIREFLY_III_ACCESS_TOKEN";
                path = "app_token.txt";
              };
              globalMounts = lib.toList {
                path = "/secrets";
                readOnly = true;
              };
            };
            config = {
              type = "configMap";
              name = "firefly-importer";
              globalMounts = lib.toList {
                path = "/.env";
                subPath = ".env";
                readOnly = true;
              };
            };
          };
        };
      };

      resources.httpRoutes.firefly.spec = {
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
      # Waterfly III sends a personal access token (Bearer), which oauth2-proxy cannot verify, so
      # the API skips it. remote_user_guard trusts the identity headers, so every one a client could
      # forge is stripped here, underscore forms included (PHP maps both to HTTP_X_AUTH_REQUEST_*).
      resources.httpRoutes.firefly-api.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          matches = lib.toList {
            path = {
              type = "PathPrefix";
              value = "/api/v1";
            };
          };
          filters = lib.toList {
            type = "RequestHeaderModifier";
            requestHeaderModifier.remove = let
              identityHeaders = [
                "X-Auth-Request-Preferred-Username"
                "X-Auth-Request-Email"
                "X-Auth-Request-User"
                "X-Auth-Request-Groups"
                "X-Forwarded-Preferred-Username"
                "X-Forwarded-User"
                "X-Forwarded-Email"
                "Remote-User"
              ];
            in
              identityHeaders ++ map (lib.replaceStrings ["-"] ["_"]) identityHeaders;
          };
          backendRefs = lib.toList {
            name = "firefly";
            port = 8080;
          };
        };
      };
      resources.httpRoutes.firefly-importer.spec = {
        hostnames = ["firefly-importer-${config.canivete.meta.people.me}.${domain}"];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        # The importer has no auth of its own but holds a Firefly access token.
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "oauth2-proxy";
            namespace = "identity";
            port = 4180;
          };
        };
      };
      # Idempotent sync-hook bootstrap (README "Conventions"): ensures the owner user, the
      # Passport keys and a personal access token for the data importer, and keeps them
      # in Secret firefly-passport (see firefly-bootstrap.php). Runs in the firefly image
      # as www-data with the app's DB credentials; the Role only reaches that one Secret
      # (create can't be limited by name, but can't read or change other Secrets).
      resources.configMaps.firefly-bootstrap.data."bootstrap.php" = builtins.readFile ./firefly-bootstrap.php;
      resources.serviceAccounts.firefly-bootstrap = {};
      resources.roles.firefly-bootstrap.rules = [
        {
          apiGroups = [""];
          resources = ["secrets"];
          verbs = ["create"];
        }
        {
          apiGroups = [""];
          resources = ["secrets"];
          resourceNames = ["firefly-passport"];
          verbs = ["get" "patch"];
        }
      ];
      resources.roleBindings.firefly-bootstrap = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = "firefly-bootstrap";
        };
        subjects = lib.toList {
          kind = "ServiceAccount";
          name = "firefly-bootstrap";
          namespace = "finance";
        };
      };
      resources.jobs.firefly-bootstrap = {
        metadata.annotations = {
          # Sync, not PostSync: the importer can't become healthy until this job has
          # written firefly-passport, so a PostSync hook would never run. It only needs
          # the database, not the firefly pod.
          "argocd.argoproj.io/hook" = "Sync";
          "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
        };
        spec = {
          backoffLimit = 6;
          activeDeadlineSeconds = 1200;
          template.spec = {
            restartPolicy = "OnFailure";
            serviceAccountName = "firefly-bootstrap";
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 33;
              runAsGroup = 33;
              fsGroup = 33;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = lib.toList {
              name = "bootstrap";
              image = with pinned.images.firefly-core; "${repository}:${tag}@${digest}";
              command = ["php" "/bootstrap/bootstrap.php"];
              env = [
                {
                  name = "ADMIN_USER";
                  value = config.canivete.meta.people.me;
                }
                {
                  # The e2e harness's own user (apps/e2e finance/firefly-ledger).
                  name = "E2E_USER";
                  value = "e2e@e2e.${domain}";
                }
                {
                  name = "APP_ENV";
                  value = "production";
                }
                {
                  name = "LOG_CHANNEL";
                  value = "stderr";
                }
                {
                  name = "DB_CONNECTION";
                  value = "pgsql";
                }
                {
                  name = "DB_HOST";
                  value = "firefly-rw";
                }
                {
                  name = "DB_PORT";
                  value = "5432";
                }
                {
                  name = "DB_DATABASE";
                  value = "firefly";
                }
                {
                  name = "DB_USERNAME";
                  value = "firefly";
                }
              ];
              volumeMounts = [
                {
                  name = "script";
                  mountPath = "/bootstrap";
                  readOnly = true;
                }
                {
                  name = "secrets";
                  mountPath = "/secrets";
                  readOnly = true;
                }
              ];
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = ["ALL"];
              };
            };
            volumes = [
              {
                name = "script";
                configMap.name = "firefly-bootstrap";
              }
              {
                name = "secrets";
                secret.secretName = "firefly";
              }
            ];
          };
        };
      };
      # Daily SimpleFIN import (firefly-simplefin.php): claims the setup token once, keeps the access
      # URL in Secret firefly-simplefin-access, maps/creates one Firefly asset account per Bridge
      # account and runs the data importer's auto-import. The Bridge allows ~24 requests/day per token
      # (more disables it) and one run uses accounts + 3: once a day, at an odd minute, never retried.
      resources.configMaps.firefly-simplefin = lib.mkIf simplefin {
        data."import.php" = builtins.readFile ./firefly-simplefin.php;
      };
      resources.externalSecrets.firefly-simplefin = lib.mkIf simplefin {
        spec.data = lib.toList {
          secretKey = "token";
          remoteRef.key = "firefly/simplefin/token";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
      };
      resources.serviceAccounts.firefly-simplefin = lib.mkIf simplefin {};
      resources.roles.firefly-simplefin = lib.mkIf simplefin {
        rules = [
          {
            apiGroups = [""];
            resources = ["secrets"];
            verbs = ["create"];
          }
          {
            apiGroups = [""];
            resources = ["secrets"];
            resourceNames = ["firefly-simplefin-access"];
            verbs = ["get" "patch"];
          }
        ];
      };
      resources.roleBindings.firefly-simplefin = lib.mkIf simplefin {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = "firefly-simplefin";
        };
        subjects = lib.toList {
          kind = "ServiceAccount";
          name = "firefly-simplefin";
          namespace = "finance";
        };
      };
      resources.cronJobs.firefly-simplefin = lib.mkIf simplefin {
        spec = {
          schedule = "41 9 * * *";
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            backoffLimit = 0;
            activeDeadlineSeconds = 1800;
            ttlSecondsAfterFinished = 172800;
            template = {
              metadata.labels."app.kubernetes.io/name" = "firefly-simplefin";
              spec = {
                restartPolicy = "Never";
                serviceAccountName = "firefly-simplefin";
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 33;
                  runAsGroup = 33;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = lib.toList {
                  name = "firefly-simplefin";
                  image = with pinned.images.firefly-data-importer; "${repository}:${tag}@${digest}";
                  resources.requests = {
                    cpu = "25m";
                    memory = "80Mi";
                  };
                  # The image's entrypoint is bypassed; config:clear drops the config cache baked into the image.
                  command = ["sh" "-c" "cd /var/www/html && php artisan config:clear >/dev/null && php /simplefin/import.php"];
                  env =
                    lib.mapAttrsToList (name: value: {inherit name value;}) {
                      FIREFLY_III_URL = "http://firefly.finance.svc.cluster.local:8080";
                      VANITY_URL = "https://${hostname}";
                      IMPORT_DIR_ALLOWLIST = "/tmp/simplefin";
                      IGNORE_DUPLICATE_ERRORS = "true";
                      # info, not debug: debug logs print the access URL (its credentials)
                      LOG_CHANNEL = "stderr";
                      LOG_LEVEL = "info";
                      # one try per request: retries count against the Bridge's daily limit
                      SIMPLEFIN_RETRY_ATTEMPTS = "1";
                    }
                    ++ lib.toList {
                      name = "FIREFLY_III_ACCESS_TOKEN";
                      valueFrom.secretKeyRef = {
                        name = "firefly-passport";
                        key = "FIREFLY_III_ACCESS_TOKEN";
                      };
                    };
                  volumeMounts = [
                    {
                      name = "script";
                      mountPath = "/simplefin";
                      readOnly = true;
                    }
                    {
                      name = "token";
                      mountPath = "/secrets/simplefin";
                      readOnly = true;
                    }
                  ];
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = ["ALL"];
                  };
                };
                volumes = [
                  {
                    name = "script";
                    configMap.name = "firefly-simplefin";
                  }
                  {
                    name = "token";
                    secret.secretName = "firefly-simplefin";
                  }
                ];
              };
            };
          };
        };
      };
      resources.externalSecrets = {
        firefly.spec.data = [
          {
            secretKey = "app_key.txt";
            remoteRef.key = "firefly/app_key";
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
      };
    };
    oauth2Proxy.upstreams."firefly-importer-${config.canivete.meta.people.me}.${domain}" = {
      url = "http://firefly-importer.finance.svc.cluster.local:8080";
      namespace = "finance";
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://firefly.finance.svc.cluster.local:8080";
      namespace = "finance";
    };
  };
}
