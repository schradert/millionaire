# RSS reader. Clients: web UI (Keycloak OIDC), newsboat (miniflux API) and
# elfeed-protocol (Fever API), both as tristan with his generated password.
{config, ...}: let
  inherit (config.canivete.meta) domain people;
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    hostname = "rss.${domain}";
    port = 8080;
    # apps/app-bootstrap miniflux (>= 0.17.0): creates tristan as an admin linked to his
    # Keycloak `sub`, with the generated password, and turns on his Fever API. Until its image
    # is pinned, his first OIDC login creates (and links) a plain user instead.
    bootstrapped = pinned.images ? app-bootstrap-miniflux;
  in {
    portal.apps.miniflux = {
      title = "Miniflux";
      description = "RSS reader";
    };
    gatus.endpoints.miniflux = {
      url = "https://${hostname}/healthcheck";
      group = "internal";
    };

    applications.keycloak.resources.keycloakClients.miniflux.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "miniflux";
        create = true;
      };
      definition = {
        clientId = "miniflux";
        name = "Miniflux";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/oauth2/oidc/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    applications.miniflux = {
      namespace = "home";
      postgres.enable = true;
      # Break-glass admin, created by miniflux itself (CREATE_ADMIN).
      generatedSecrets.miniflux-admin = {
        key = "password";
        bitwarden = "miniflux/admin-password";
      };
      # tristan's password, read by the feed readers (modules/feeds.nix).
      generatedSecrets.miniflux-tristan = {
        key = "password";
        bitwarden = "miniflux/tristan-password";
      };
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-miniflux; "${repository}:${tag}@${digest}";
        args = ["miniflux"];
        env = {
          MINIFLUX_URL = "http://miniflux.home.svc.cluster.local:${toString port}";
          OIDC_USERNAME = people.me;
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
          USER_PASSWORD_FILE = "/secrets/user/password";
          KEYCLOAK_PASSWORD_FILE = "/secrets/keycloak/password";
        };
        secrets = {
          admin = "miniflux-admin";
          user = "miniflux-tristan";
          keycloak = "miniflux-keycloak-admin";
        };
      };
      helm.releases.miniflux = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.miniflux = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.miniflux = {
              image = pinned.images.miniflux;
              envFrom = [{configMapRef.name = "miniflux";}];
              ports = lib.toList {
                name = "http";
                containerPort = port;
              };
              env.DATABASE_URL.valueFrom.secretKeyRef = {
                name = "miniflux-app";
                key = "uri";
              };
              probes = let
                probe = path: {
                  enabled = true;
                  custom = true;
                  spec.httpGet = {
                    inherit path;
                    port = "http";
                  };
                };
              in {
                liveness = probe "/liveness";
                readiness = probe "/readiness";
                startup = lib.recursiveUpdate (probe "/liveness") {
                  spec.failureThreshold = 30;
                  spec.periodSeconds = 10;
                };
              };
            };
          };
          service.miniflux.ports.http.port = port;
          serviceMonitor.miniflux = {
            serviceName = "miniflux";
            endpoints = lib.toList {
              port = "http";
              path = "/metrics";
              interval = "1m";
            };
          };
          persistence = {
            admin = {
              type = "secret";
              name = "miniflux-admin";
              globalMounts = lib.toList {
                path = "/secrets/admin";
                readOnly = true;
              };
            };
            oidc = {
              type = "secret";
              name = "miniflux";
              globalMounts = lib.toList {
                path = "/secrets/oidc";
                readOnly = true;
              };
            };
          };
          configMaps.miniflux.data = {
            BASE_URL = "https://${hostname}";
            LISTEN_ADDR = "0.0.0.0:${toString port}";
            RUN_MIGRATIONS = "1";
            CREATE_ADMIN = "1";
            ADMIN_USERNAME = "admin";
            ADMIN_PASSWORD_FILE = "/secrets/admin/password";
            OAUTH2_PROVIDER = "oidc";
            OAUTH2_CLIENT_ID = "miniflux";
            OAUTH2_CLIENT_SECRET_FILE = "/secrets/oidc/client-secret";
            OAUTH2_REDIRECT_URL = "https://${hostname}/oauth2/oidc/callback";
            OAUTH2_OIDC_DISCOVERY_ENDPOINT = "https://keycloak.${domain}/realms/default";
            OAUTH2_OIDC_PROVIDER_NAME = "Keycloak";
            OAUTH2_USER_CREATION =
              if bootstrapped
              then "0"
              else "1";
            METRICS_COLLECTOR = "1";
            # Pod network (Cilium pool), for the ServiceMonitor scrape.
            METRICS_ALLOWED_NETWORKS = "10.0.0.0/8";
          };
          route.miniflux = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "miniflux";
                inherit port;
              };
            };
          };
        };
      };
      resources.externalSecrets = {
        miniflux.spec.data = lib.toList {
          secretKey = "client-secret";
          remoteRef.key = "miniflux";
          remoteRef.property = "client-secret";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
        # Keycloak master-realm admin, to resolve tristan's `sub`.
        miniflux-keycloak-admin = lib.mkIf bootstrapped {
          spec.data = lib.toList {
            secretKey = "password";
            remoteRef.key = "keycloak/admin/password";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          };
        };
      };
    };
  };
}
