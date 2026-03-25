{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    kratosPublicHost = "auth.${domain}";
    uiHost = "login.${domain}";
    adminHost = "admin.${domain}";
  in {
    gatus.endpoints.kratos = { url = "https://${kratosPublicHost}"; group = "internal"; };
    applications.kratos = {
      namespace = "identity";
      postgres.enable = true;
      postgres.database = "kratos";
      helm.releases.kratos = {
        chart = lib.helm.downloadHelmChart {
          chart = "kratos";
          version = "0.60.1";
          repo = "https://k8s.ory.sh/helm/charts";
          chartHash = "sha256-lMLBGK4kBXJVmoDO2f2GN+GE1ipkUGliRBEEt/Huvlg=";
        };
        values = {
          secret.enabled = false;
          kratos = {
            automigration = {
              enabled = true;
              type = "initContainer";
            };
            config = {
              dsn = "postgres://kratos:$(DB_PASSWORD)@kratos-rw.identity.svc.cluster.local:5432/kratos?sslmode=disable";
              cookies.domain = domain;
              cookies.same_site = "Lax";
              serve = {
                public = {
                  base_url = "https://${kratosPublicHost}";
                  cors = {
                    enabled = true;
                    allowed_origins = [
                      "https://${uiHost}"
                      "https://${adminHost}"
                      "https://*.${domain}"
                    ];
                  };
                };
                admin.base_url = "http://kratos-admin.identity.svc.cluster.local:4434";
              };
              selfservice = {
                default_browser_return_url = "https://${uiHost}";
                methods = {
                  password.enabled = true;
                  totp = {
                    enabled = true;
                    config.issuer = domain;
                  };
                  webauthn = {
                    enabled = true;
                    config = {
                      rp = {
                        display_name = "Millionaire Homelab";
                        id = domain;
                        origins = ["https://${uiHost}"];
                      };
                      passwordless = false;
                    };
                  };
                  lookup_secret.enabled = true;
                  link.enabled = true;
                  code.enabled = true;
                };
                flows = {
                  login = {
                    ui_url = "https://${uiHost}/login";
                    lifespan = "1h";
                  };
                  registration = {
                    ui_url = "https://${uiHost}/registration";
                    lifespan = "1h";
                    after.password.hooks = [{hook = "session";}];
                  };
                  verification = {
                    ui_url = "https://${uiHost}/verification";
                    enabled = true;
                    use = "code";
                  };
                  recovery = {
                    ui_url = "https://${uiHost}/recovery";
                    enabled = true;
                    use = "code";
                  };
                  settings = {
                    ui_url = "https://${uiHost}/settings";
                    privileged_session_max_age = "15m";
                    required_aal = "highest_available";
                  };
                  error.ui_url = "https://${uiHost}/error";
                  logout.after.default_browser_return_url = "https://${uiHost}/login";
                };
              };
              session = {
                lifespan = "24h";
                cookie = {
                  inherit domain;
                  same_site = "Lax";
                };
              };
              identity = {
                default_schema_id = "default";
                schemas = [
                  {
                    id = "default";
                    url = "file:///etc/kratos/identity.schema.json";
                  }
                ];
              };
              # TODO configure SMTP for email verification/recovery
              courier.smtp.connection_uri = "smtp://localhost:1025/?disable_starttls=true";
              secrets = {
                cookie = ["$(SECRETS_COOKIE)"];
                cipher = ["$(SECRETS_CIPHER)"];
              };
            };
          };
          deployment = {
            automountServiceAccountToken = true;
            extraVolumes = [
              {
                name = "identity-schema";
                configMap.name = "kratos-identity-schema";
              }
            ];
            extraVolumeMounts = [
              {
                name = "identity-schema";
                mountPath = "/etc/kratos/identity.schema.json";
                subPath = "identity.schema.json";
                readOnly = true;
              }
            ];
            extraEnv = [
              {
                name = "DB_PASSWORD";
                valueFrom.secretKeyRef = {
                  name = "kratos";
                  key = "db_password";
                };
              }
              {
                name = "SECRETS_COOKIE";
                valueFrom.secretKeyRef = {
                  name = "kratos";
                  key = "cookie_secret";
                };
              }
              {
                name = "SECRETS_CIPHER";
                valueFrom.secretKeyRef = {
                  name = "kratos";
                  key = "cipher_secret";
                };
              }
            ];
          };
          job.extraEnv = [
            {
              name = "DB_PASSWORD";
              valueFrom.secretKeyRef = {
                name = "kratos";
                key = "db_password";
              };
            }
          ];
        };
      };

      # Kratos Self-Service UI
      helm.releases.kratos-ui = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.kratos-ui = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.kratos-ui = {
              image = {
                repository = "oryd/kratos-selfservice-ui-node";
                tag = "v0.14.1";
              };
              env = {
                KRATOS_PUBLIC_URL = "http://kratos-public.identity.svc.cluster.local";
                KRATOS_BROWSER_URL = "https://${kratosPublicHost}";
                HYDRA_ADMIN_URL = "http://hydra-admin.identity.svc.cluster.local:4445";
                COOKIE_SECRET.valueFrom.secretKeyRef = {
                  name = "kratos-ui";
                  key = "cookie_secret";
                };
                CSRF_COOKIE_NAME = "__Secure-${domain}-x-csrf-token";
                CSRF_COOKIE_SECRET.valueFrom.secretKeyRef = {
                  name = "kratos-ui";
                  key = "csrf_secret";
                };
              };
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.kratos-ui.ports.http.port = 3000;
        };
      };

      # Admin UI for identity management
      helm.releases.kratos-admin-ui = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.kratos-admin-ui.containers.kratos-admin-ui = {
            image = {
              repository = "licenseware/ory-admin-ui";
              tag = "v0.1.1";
            };
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.kratos-admin-ui.ports.http.port = 8080;
        };
      };

      resources.serviceAccounts.kratos.automountServiceAccountToken = lib.mkForce true;

      # Identity schema
      resources.configMaps.kratos-identity-schema.data."identity.schema.json" = builtins.toJSON {
        "$id" = "https://${domain}/schemas/default.json";
        "$schema" = "http://json-schema.org/draft-07/schema#";
        title = "Person";
        type = "object";
        properties.traits = {
          type = "object";
          required = ["email"];
          properties = {
            email = {
              type = "string";
              format = "email";
              title = "Email";
              "ory.sh/kratos" = {
                credentials = {
                  password.identifier = true;
                  webauthn.identifier = true;
                  totp.account_name = true;
                };
                verification.via = "email";
                recovery.via = "email";
              };
            };
            name = {
              type = "object";
              properties = {
                first = {
                  type = "string";
                  title = "First Name";
                };
                last = {
                  type = "string";
                  title = "Last Name";
                };
              };
            };
          };
        };
      };

      resources.externalSecrets = {
        kratos.spec.target.template.data = {
          dsn = "postgres://kratos:{{ .db_password }}@kratos-rw.identity.svc.cluster.local:5432/kratos?sslmode=disable";
          db_password = "{{ .db_password }}";
          cookie_secret = "{{ .cookie_secret }}";
          cipher_secret = "{{ .cipher_secret }}";
          smtpConnectionURI = "smtp://localhost:1025/?disable_starttls=true";
        };
        kratos.spec.data = [
          {
            secretKey = "cookie_secret";
            remoteRef.key = "ory/kratos/secret";
            sourceRef.storeRef = {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
          }
          {
            secretKey = "cipher_secret";
            remoteRef.key = "ory/kratos/cipher";
            sourceRef.storeRef = {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
          }
          {
            secretKey = "db_password";
            remoteRef = {
              key = "kratos-app";
              property = "password";
            };
            sourceRef.storeRef = {
              name = "kubernetes-identity";
              kind = "ClusterSecretStore";
            };
          }
        ];
        kratos-ui.spec.data = [
          {
            secretKey = "cookie_secret";
            remoteRef.key = "ory/ui/cookie-secret";
            sourceRef.storeRef = {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
          }
          {
            secretKey = "csrf_secret";
            remoteRef.key = "ory/ui/csrf-secret";
            sourceRef.storeRef = {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
          }
        ];
      };
      resources.httpRoutes.kratos-public.spec = {
        hostnames = [kratosPublicHost];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "kratos-public";
            port = 80;
          };
        };
      };
      resources.httpRoutes.kratos-ui.spec = {
        hostnames = [uiHost];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "kratos-ui";
            port = 3000;
          };
        };
      };
      resources.httpRoutes.kratos-admin-ui.spec = {
        hostnames = [adminHost];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "kratos-admin-ui";
            port = 8080;
          };
        };
      };
    };
  };
}
