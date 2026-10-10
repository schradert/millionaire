{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "ryot.${domain}";
    # Ryot has no config-file/bootstrap path for OIDC users: the account is created
    # (and linked by the OIDC `sub`) on first OIDC login, and the very first user on
    # an empty instance becomes admin. Registration must therefore be open for that
    # one login, so until it has happened the instance stays behind oauth2-proxy.
    # Once tristan has logged in via Keycloak (he is then the admin), flip this to
    # true: registration closes and oauth2-proxy is dropped in the same sync.
    claimed = false;
  in {
    gatus.endpoints.ryot = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Native OIDC: callback is FRONTEND_URL + /api/auth. Ryot only requests the
    # `email` scope and uses the email claim as the username; roles are NOT mapped
    # from claims (first user = admin, others are normal users).
    applications.keycloak.resources.keycloakClients.ryot.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "ryot";
        create = true;
      };
      definition = {
        clientId = "ryot";
        name = "Ryot";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/api/auth"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.ryot = {
      namespace = "media";
      postgres.enable = true;
      helm.releases.ryot = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.ryot = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.ryot = {
              image = pinned.images.ryot;
              envFrom = [{configMapRef.name = "ryot";} {secretRef.name = "ryot";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.ryot.ports.http.port = 8000;
          configMaps.ryot.data = {
            SERVER_INSECURE_COOKIE = "false";
            FRONTEND_URL = "https://${hostname}";
            FRONTEND_OIDC_BUTTON_LABEL = "Continue with Keycloak";
            SERVER_OIDC_CLIENT_ID = "ryot";
            SERVER_OIDC_ISSUER_URL = "https://keycloak.${domain}/realms/default";
            # Password login stays as break-glass. Admin-token calls to registerUser
            # still work with registration closed.
            USERS_ALLOW_REGISTRATION = lib.boolToString (!claimed);
            VIDEO_GAMES_TWITCH_CLIENT_ID = "";
            VIDEO_GAMES_TWITCH_CLIENT_SECRET = "";
          };
          route.ryot = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList (
                if claimed
                then {
                  name = "ryot";
                  port = 8000;
                }
                else {
                  name = "oauth2-proxy";
                  namespace = "identity";
                  port = 4180;
                }
              );
            };
          };
        };
      };
      # Random once, never refreshed: ryot refuses to start without an admin token.
      resources.passwords.ryot-admin-token.spec = {
        length = 40;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.ryot-admin-token.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "ryot-admin-token";
          };
        };
      };
      resources.externalSecrets.ryot.spec.data = [
        {
          secretKey = "DATABASE_URL";
          remoteRef.key = "ryot-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "ADMIN_ACCESS_TOKEN";
          remoteRef.key = "ryot-admin-token";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "OIDC_CLIENT_SECRET";
          remoteRef.key = "ryot";
          remoteRef.property = "client-secret";
          sourceRef.storeRef.name = "kubernetes-identity";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
      resources.externalSecrets.ryot.spec.target.template.data = {
        DATABASE_URL = "postgresql://ryot:{{ .DATABASE_URL }}@ryot-rw.media.svc.cluster.local:5432/ryot";
        SERVER_ADMIN_ACCESS_TOKEN = "{{ .ADMIN_ACCESS_TOKEN }}";
        SERVER_OIDC_CLIENT_SECRET = "{{ .OIDC_CLIENT_SECRET }}";
      };
    };
    oauth2Proxy.upstreams = lib.mkIf (!claimed) {
      ${hostname} = {
        url = "http://ryot.media.svc.cluster.local:8000";
        namespace = "media";
      };
    };
  };
}
