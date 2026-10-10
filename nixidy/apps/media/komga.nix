{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  # NOTE: Komga uses an embedded H2/SQLite DB by default, no Postgres support.
  # The config PVC (which contains the DB) is backed up via volsync.
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "komga.${domain}";
    issuer = "https://keycloak.${domain}/realms/default";
    oidc = "${issuer}/protocol/openid-connect";
    # Stay behind oauth2-proxy until the bootstrap image is pinned: an
    # unclaimed server lets anyone claim it.
    bootstrapped = pinned.images ? app-bootstrap-komga;
    registration = "SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_KEYCLOAK";
    provider = "SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_KEYCLOAK";
  in {
    gatus.endpoints.komga = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Native OIDC through Spring's client config (env on the container). Komga has
    # no role mapping: it links a login to the user with the same verified email, so
    # tristan's Keycloak login IS the admin the bootstrap claimed the server with.
    # Unknown emails are rejected (KOMGA_OAUTH2_ACCOUNT_CREATION stays false) and
    # password login stays on as break-glass. Explicit endpoints instead of
    # issuer-uri: Spring would otherwise fetch discovery at startup and Komga
    # would fail to boot whenever Keycloak is down.
    applications.keycloak.resources.keycloakClients.komga.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "komga";
        create = true;
      };
      definition = {
        clientId = "komga";
        name = "Komga";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/login/oauth2/code/keycloak"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.komga = {
      namespace = "media";
      generatedSecrets.komga-admin = {
        key = "password";
        bitwarden = "komga/admin-password";
      };
      resources.externalSecrets.komga-oidc.spec.data = lib.toList {
        secretKey = "client_secret";
        remoteRef.key = "komga";
        remoteRef.property = "client-secret";
        sourceRef.storeRef.name = "kubernetes-identity";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
      # Idempotent post-sync bootstrap (apps/app-bootstrap komga, >= 0.5.0):
      # claims the server as tristan's email, creates the Comics library.
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-komga; "${repository}:${tag}@${digest}";
        args = ["komga"];
        env = {
          KOMGA_URL = "http://komga.media.svc.cluster.local:25600";
          ADMIN_EMAIL = people.my.profiles.personal.email;
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
        };
        secrets.admin = "komga-admin";
      };
      volsync.pvcs.komga.title = "komga";
      helm.releases.komga = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.komga.containers.komga = {
            image = pinned.images.komga;
            env = {
              KOMGA_OAUTH2_ACCOUNT_CREATION = "false";
              "${registration}_CLIENT_NAME" = "Keycloak";
              "${registration}_CLIENT_ID" = "komga";
              "${registration}_CLIENT_SECRET".valueFrom.secretKeyRef = {
                name = "komga-oidc";
                key = "client_secret";
              };
              "${registration}_PROVIDER" = "keycloak";
              "${registration}_SCOPE" = "openid,email,profile";
              "${registration}_AUTHORIZATION_GRANT_TYPE" = "authorization_code";
              "${registration}_REDIRECT_URI" = "{baseUrl}/{action}/oauth2/code/{registrationId}";
              "${provider}_AUTHORIZATION_URI" = "${oidc}/auth";
              "${provider}_TOKEN_URI" = "${oidc}/token";
              "${provider}_USER_INFO_URI" = "${oidc}/userinfo";
              "${provider}_JWK_SET_URI" = "${oidc}/certs";
              "${provider}_USER_NAME_ATTRIBUTE" = "sub";
            };
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.komga.ports.http.port = 25600;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/config";}];
          };
          persistence.media-comics = {
            type = "persistentVolumeClaim";
            existingClaim = "media-comics";
            advancedMounts.komga.komga = [
              {
                path = "/media/comics";
                readOnly = true;
              }
            ];
          };
          route.komga = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList (
                if bootstrapped
                then {
                  name = "komga";
                  port = 25600;
                }
                else {
                  name = "oauth2-proxy";
                  namespace = "identity";
                  port = 4180;
                }
              );
            };
          };
          # OPDS clients (e-readers) can't complete OIDC, so /opds always skips
          # the browser login path. All v1.2/v2 feed links stay under /opds and Komga
          # enforces HTTP Basic / X-API-Key auth on every one of them.
          route.komga-opds = {
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
                  value = "/opds";
                };
              };
              backendRefs = lib.toList {
                name = "komga";
                port = 25600;
              };
            };
          };
        };
      };
    };
    oauth2Proxy.upstreams = lib.mkIf (!bootstrapped) {
      ${hostname} = {
        url = "http://komga.media.svc.cluster.local:25600";
        namespace = "media";
      };
    };
  };
}
