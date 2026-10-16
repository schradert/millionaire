{config, ...}: let
  inherit (config.canivete.meta) domain people;
  hostname = "git.${domain}";
  # Floccus (docs/connections.md) syncs browser bookmarks to this repo over git+https.
  bookmarks = "${people.me}/bookmarks";
in {
  # `tea` logs in through Forgejo's built-in `tea` OAuth2 app (loopback
  # redirect), so its token comes from a Forgejo SSO login (Keycloak) and is
  # refreshed by tea; no personal access token. One-time per host: `tea-login`.
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = [pkgs.tea];
      home.shellAliases.tea-login = "tea login add --name trdos --url https://${hostname} --oauth";
    };
  };
  nixidy = {
    config,
    lib,
    pinned,
    ...
  }: let
    # apps/app-bootstrap forgejo (>= 0.18.0): tristan's user, the private bookmarks repo and
    # a write:repository token for Floccus in forgejo-tristan-floccus, pushed to Bitwarden
    # forgejo/tristan/floccus-token.
    bootstrapped = pinned.images ? app-bootstrap-forgejo;
  in {
    portal.apps.forgejo.groups = ["admin"];
    # Browser telemetry: custom/header.tmpl is Forgejo's own hook for extra <head> content.
    faro.apps.forgejo.origin = "https://${hostname}";
    gatus.endpoints.forgejo = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Web UI behind oauth2-proxy (admin); Forgejo OIDC still logs in.
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://forgejo-http.development.svc.cluster.local:3000";
      namespace = "development";
    };

    # Keycloak OIDC client — keycloak-operator syncs secret to K8s
    applications.keycloak.resources.keycloakClients.forgejo.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "forgejo";
        create = true;
      };
      definition = {
        clientId = "forgejo";
        name = "Forgejo";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/user/oauth2/keycloak/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };

    applications.forgejo = {
      namespace = "development";
      generatedSecrets.forgejo-admin-password = {
        key = "password";
        bitwarden = "forgejo/admin-password";
      };
      postgres.enable = true;
      postgres.instances = 2;
      postgres.avoidNodes = ["sirver"];
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-forgejo; "${repository}:${tag}@${digest}";
        args = ["forgejo"];
        env = {
          FORGEJO_URL = "http://forgejo-http.development.svc.cluster.local:3000";
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
          USER = people.me;
          USER_EMAIL = people.my.profiles.personal.email;
          REPO = baseNameOf bookmarks;
          TOKEN_NAME = "floccus";
          TOKEN_SCOPES = "write:repository";
          SECRET_NAME = "forgejo-tristan-floccus";
        };
        secrets.admin = "forgejo-admin";
        rules = [
          {
            apiGroups = [""];
            resources = ["secrets"];
            verbs = ["create"];
          }
          {
            apiGroups = [""];
            resources = ["secrets"];
            resourceNames = ["forgejo-tristan-floccus"];
            verbs = ["get" "patch"];
          }
        ];
      };
      # Repos and attachments live on the chart's `persistence` PVC (the chart
      # names it gitea-shared-storage); forgejo-1 is the CNPG database volume.
      volsync.pvcs.data-forgejo-0 = {
        title = "gitea-shared-storage";
        restore = false;
      };

      helm.releases.forgejo = {
        chart = pinned.charts.forgejo;
        values = {
          # digest only: the chart appends -rootless to its appVersion tag.
          image.digest = pinned.images.forgejo.digest;
          service.ssh = {
            type = "LoadBalancer";
            port = 22;
            annotations."lbipam.cilium.io/ips" = "192.168.50.251";
          };

          persistence = {
            size = "50Gi";
            storageClass = "ceph-block";
          };

          # Templates are read at start-up: roll the Pod when the snippet changes.
          deployment.annotations."reloader.stakater.com/auto" = "true";
          extraVolumes = lib.toList {
            name = "faro";
            configMap.name = "forgejo-faro";
          };
          extraContainerVolumeMounts = lib.toList {
            name = "faro";
            mountPath = "/data/gitea/templates/custom/header.tmpl";
            subPath = "header.tmpl";
            readOnly = true;
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
                # Keycloak sends short group names (groups scope, full.path off).
                adminGroup = "admin";
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
                # Password form kept for the break-glass forgejo-admin.
                ENABLE_INTERNAL_SIGNIN = true;
              };

              oauth2_client = {
                ENABLE_AUTO_REGISTRATION = true;
                ACCOUNT_LINKING = "auto";
                USERNAME = "preferred_username";
              };

              federation.ENABLED = true;
              metrics.ENABLED = true;
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
        configMaps.forgejo-faro.data."header.tmpl" = ''
          <script>
          ${config.faro.snippet "forgejo"}</script>
        '';
        # The chart's own ServiceMonitor is gated on cluster capabilities, which helm template lacks.
        serviceMonitors.forgejo.spec = {
          selector.matchLabels = {
            "app.kubernetes.io/name" = "forgejo";
            "app.kubernetes.io/component" = "http";
          };
          endpoints = lib.toList {
            port = "http";
            path = "/metrics";
            interval = "1m";
          };
        };
        httpRoutes.forgejo.spec = {
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
        # git over HTTPS (git and git-lfs User-Agents), the token API and the
        # OAuth2 token endpoint (tea's code exchange and refresh) skip
        # oauth2-proxy; ssh is its own LoadBalancer. Header and path matches
        # outrank the plain "/" route (Gateway API precedence).
        httpRoutes.forgejo-git.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            matches = lib.toList {
              headers = lib.toList {
                name = "User-Agent";
                type = "RegularExpression";
                value = "^git(-lfs)?/.*";
              };
            };
            backendRefs = lib.toList {
              name = "forgejo-http";
              port = 3000;
            };
          };
        };
        httpRoutes.forgejo-api.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            matches = [
              {
                path = {
                  type = "PathPrefix";
                  value = "/api/";
                };
              }
              {
                path = {
                  type = "Exact";
                  value = "/login/oauth/access_token";
                };
              }
            ];
            backendRefs = lib.toList {
              name = "forgejo-http";
              port = 3000;
            };
          };
        };

        # Floccus: a browser extension, so neither the git User-Agent route nor
        # oauth2-proxy fits; only the bookmarks repo's smart-HTTP paths skip oauth2-proxy,
        # and Forgejo checks the token (private repo).
        httpRoutes.forgejo-floccus = lib.mkIf bootstrapped {
          spec = {
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
                  value = "/${bookmarks}.git";
                };
              };
              backendRefs = lib.toList {
                name = "forgejo-http";
                port = 3000;
              };
            };
          };
        };
        pushSecrets.forgejo-tristan-floccus = lib.mkIf bootstrapped {
          spec = {
            secretStoreRefs = lib.toList {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
            selector.secret.name = "forgejo-tristan-floccus";
            data = lib.toList {
              match = {
                secretKey = "token";
                remoteRef.remoteKey = "forgejo/tristan/floccus-token";
              };
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

          # Fixed admin username ("admin" is reserved by Forgejo); password
          # generated in-cluster
          forgejo-admin.spec = {
            target.template.data = {
              username = "forgejo-admin";
              password = "{{ .password }}";
            };
            data = [
              {
                secretKey = "password";
                remoteRef = {
                  key = "forgejo-admin-password";
                  property = "password";
                };
                sourceRef.storeRef = {
                  name = "kubernetes-development";
                  kind = "ClusterSecretStore";
                };
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
                  property = "client-id";
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
                  property = "client-secret";
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
