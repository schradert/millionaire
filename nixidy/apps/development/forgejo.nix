{config, ...}: {
  nixidy = {lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "git.${domain}";
  in {
    gatus.endpoints.forgejo = {
      url = "https://${hostname}";
      group = "external";
    };

    # Keycloak OIDC client — keycloak-operator syncs secret to K8s
    applications.keycloak.resources.keycloakClients.forgejo.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "forgejo";
        name = "Forgejo";
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/user/oauth2/keycloak/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    applications.forgejo = {
      namespace = "development";
      postgres.enable = true;
      # Forgejo chart deploys a StatefulSet; default PVC is `data-forgejo-0`
      volsync.pvcs.data-forgejo-0.title = "data-forgejo-0";

      helm.releases.forgejo = {
        chart = lib.helm.downloadHelmChart {
          chart = "forgejo";
          version = "16.2.1";
          repo = "oci://code.forgejo.org/forgejo-helm";
          chartHash = "sha256-aA1ZUGa6q2sm1GYsxnex/Z2THC9GsVYvNz6e88Dl1XM=";
        };
        values = {
          service.ssh = {
            type = "LoadBalancer";
            port = 22;
            annotations."lbipam.cilium.io/ips" = "192.168.50.251";
          };

          persistence = {
            size = "50Gi";
            storageClass = "ceph-block";
          };

          gitea = {
            admin.existingSecret = "forgejo-admin";

            oauth = [
              {
                name = "keycloak";
                provider = "openidConnect";
                existingSecret = "forgejo-oidc";
                autoDiscoverUrl = "https://keycloak.${domain}/realms/default/.well-known/openid-configuration";
                groupClaimName = "groups";
                adminGroup = "/admin";
              }
            ];

            # DB password injected securely via additionalConfigSources
            # Secret key "database" contains "PASSWD=<password>" (env2ini convention)
            additionalConfigSources = [
              {secret.secretName = "forgejo-db-config";}
            ];

            config = {
              server = {
                DOMAIN = hostname;
                ROOT_URL = "https://${hostname}/";
                SSH_DOMAIN = hostname;
                SSH_PORT = 22;
                SSH_LISTEN_PORT = 2222;
                LFS_START_SERVER = true;
              };

              database = {
                DB_TYPE = "postgres";
                HOST = "forgejo-rw:5432";
                NAME = "forgejo";
                USER = "forgejo";
              };

              service = {
                DISABLE_REGISTRATION = false;
                ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
                SHOW_REGISTRATION_BUTTON = false;
                ENABLE_INTERNAL_SIGNIN = false;
              };

              oauth2_client = {
                ENABLE_AUTO_REGISTRATION = true;
                ACCOUNT_LINKING = "auto";
                USERNAME = "preferred_username";
              };

              federation.ENABLED = true;
              packages.ENABLED = true;
              actions.ENABLED = true;
              session.PROVIDER = "db";
              cache.ADAPTER = "memory";

              mailer = {
                ENABLED = true;
                PROTOCOL = "smtp";
                SMTP_ADDR = "stalwart.mail.svc.cluster.local";
                SMTP_PORT = 25;
                FROM = "Forgejo <noreply@${domain}>";
              };
            };
          };
        };
      };

      resources = {
        httpRoutes.forgejo.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "external";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "forgejo-http";
              port = 3000;
            };
          };
        };

        externalSecrets = {
          # CNPG database password → ini-style config source for env2ini
          forgejo-db-config.spec = {
            target.template.data.database = "PASSWD={{ .password }}";
            data = lib.toList {
              secretKey = "password";
              remoteRef = {
                key = "forgejo-app";
                property = "password";
              };
              sourceRef.storeRef = {
                name = "kubernetes-development";
                kind = "ClusterSecretStore";
              };
            };
          };

          # Admin credentials from Bitwarden
          forgejo-admin.spec = {
            secretStoreRef = {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
            data = [
              {
                secretKey = "username";
                remoteRef.key = "forgejo/admin/username";
              }
              {
                secretKey = "password";
                remoteRef.key = "forgejo/admin/password";
              }
            ];
          };

          # OIDC client credentials from Keycloak operator
          forgejo-oidc.spec = {
            target.template.data = {
              key = "{{ .clientId }}";
              secret = "{{ .clientSecret }}";
            };
            data = [
              {
                secretKey = "clientId";
                remoteRef = {
                  key = "forgejo";
                  property = "CLIENT_ID";
                };
                sourceRef.storeRef = {
                  name = "kubernetes-identity";
                  kind = "ClusterSecretStore";
                };
              }
              {
                secretKey = "clientSecret";
                remoteRef = {
                  key = "forgejo";
                  property = "CLIENT_SECRET";
                };
                sourceRef.storeRef = {
                  name = "kubernetes-identity";
                  kind = "ClusterSecretStore";
                };
              }
            ];
          };
        };
      };
    };
  };
}
