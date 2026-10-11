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
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/health";
      spec.httpGet.port = "http";
    };
  in {
    gatus.endpoints.firefly = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.firefly = {
      namespace = "finance";
      postgres.enable = true;
      helm.releases.firefly = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.firefly = {
            annotations."reloader.stakater.com/auto" = "true";
            pod.securityContext.fsGroup = 33;
            containers.firefly = {
              image = pinned.images.firefly-core;
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
              # Personal access token minted by the firefly-bootstrap job.
              env.FIREFLY_III_ACCESS_TOKEN_FILE = "/secrets/app_token.txt";
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
            # Only the token, not the signing keys that share the Secret.
            secrets = {
              type = "secret";
              name = "firefly-passport";
              globalMounts = lib.toList {
                path = "/secrets/app_token.txt";
                subPath = "FIREFLY_III_ACCESS_TOKEN";
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
      # Idempotent post-sync bootstrap (README "Conventions"): ensures the owner user, the
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
          "argocd.argoproj.io/hook" = "PostSync";
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
