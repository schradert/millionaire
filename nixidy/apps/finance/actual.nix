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
    hostname = "actual.${domain}";
    # Stay behind oauth2-proxy until the bootstrap image is pinned: an unbootstrapped
    # server lets anyone set the server password and claim it.
    bootstrapped = pinned.images ? app-bootstrap-actual;
  in {
    gatus.endpoints.actual = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Native OpenID, no oauth2-proxy (the Electron/mobile sync clients need the bare server URL).
    # The bootstrap job sets the server password (break-glass), pre-creates the Keycloak user
    # `tristan` as an ADMIN (Actual matches preferred_username against its users and, with
    # userCreationMode=manual, only lets pre-created users in), then enables OpenID via
    # /openid/enable. Actual ignores the `groups` claim, so there is no role mapping.
    # Callback path is fixed by Actual.
    applications.keycloak.resources.keycloakClients.actual.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "actual";
        create = true;
      };
      definition = {
        clientId = "actual";
        name = "Actual Budget";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/openid/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.actual = {
      namespace = "finance";
      generatedSecrets.actual-admin = {
        key = "password";
        bitwarden = "actual/admin-password";
      };
      resources.externalSecrets.actual-oidc.spec.data = lib.toList {
        secretKey = "client_secret";
        remoteRef.key = "actual";
        remoteRef.property = "client-secret";
        sourceRef.storeRef.name = "kubernetes-identity";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
      # Idempotent post-sync bootstrap (apps/app-bootstrap actual, >= 0.12.0).
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-actual; "${repository}:${tag}@${digest}";
        args = ["actual"];
        env = {
          ACTUAL_URL = "http://actual.finance.svc.cluster.local:5006";
          ACTUAL_PUBLIC_URL = "https://${hostname}";
          ADMIN_USER = people.me;
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
          OIDC_AUTHORITY = "https://keycloak.${domain}/realms/default";
          OIDC_CLIENT_ID = "actual";
          OIDC_CLIENT_SECRET_FILE = "/secrets/oidc/client_secret";
        };
        secrets = {
          admin = "actual-admin";
          oidc = "actual-oidc";
        };
      };
      volsync.pvcs.actual.title = "actual";
      helm.releases.actual = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.actual.containers.actual = {
            image = pinned.images.actual-server;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.actual.ports.http.port = 5006;
          persistence.data = {
            type = "persistentVolumeClaim";
            size = "1Gi";
            accessMode = "ReadWriteOnce";
          };
        };
      };
      resources.httpRoutes.actual.spec = {
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
              name = "actual";
              port = 5006;
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
    oauth2Proxy.upstreams = lib.mkIf (!bootstrapped) {
      ${hostname} = {
        url = "http://actual.finance.svc.cluster.local:5006";
        namespace = "finance";
      };
    };
  };
}
