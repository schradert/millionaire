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
    # false: no ExternalSecret, nothing passed to the bootstrap. true once Bitwarden holds
    # `actual/simplefin/token` (docs/manual-steps.md, "Bank sync (SimpleFIN)"). SimpleFIN secrets are
    # GLOBAL in Actual (26.10.0 scopes only Pluggy.ai per budget file): every Actual user could sync
    # these banks, so nobody else gets Actual accounts with bank sync until SimpleFIN is file-scoped.
    simplefin = true;
  in {
    portal.apps.actual = {
      title = "Actual Budget";
      description = "Zero-based budgeting";
    };
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
        env =
          lib.optionalAttrs simplefin {
            SIMPLEFIN_TOKEN_FILE = "/secrets/simplefin/token";
          }
          // {
            ACTUAL_URL = "http://actual.finance.svc.cluster.local:5006";
            ACTUAL_PUBLIC_URL = "https://${hostname}";
            ADMIN_USER = people.me;
            ADMIN_PASSWORD_FILE = "/secrets/admin/password";
            OIDC_AUTHORITY = "https://keycloak.${domain}/realms/default";
            OIDC_CLIENT_ID = "actual";
            OIDC_CLIENT_SECRET_FILE = "/secrets/oidc/client_secret";
          };
        secrets =
          lib.optionalAttrs simplefin {
            simplefin = "actual-simplefin";
          }
          // {
            admin = "actual-admin";
            oidc = "actual-oidc";
          };
      };
      resources.externalSecrets.actual-simplefin = lib.mkIf simplefin {
        spec.data = lib.toList {
          secretKey = "token";
          remoteRef.key = "actual/simplefin/token";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
      };
      volsync.pvcs.actual.title = "actual";
      helm.releases.actual = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          # The bootstrap pre-creates the owner's user (owner=0) so OpenID lets it in, but then the
          # first-login path that marks the owner never runs and the UI keeps offering "create the
          # owner". Actual has no API to set the owner, so mark it in account.sqlite before start,
          # only when no named owner exists (a no-op on a fresh volume or once an owner is set).
          controllers.actual.initContainers.owner = {
            image = pinned.images.actual-server;
            workingDir = "/app";
            env.OWNER = people.me;
            command = [
              "node"
              "-e"
              ''
                const fs = require("fs"), db = "/data/server-files/account.sqlite";
                if (!fs.existsSync(db)) process.exit(0);
                const d = new (require("better-sqlite3"))(db);
                const has = d.prepare("SELECT count(*) n FROM sqlite_master WHERE name = 'users'").get().n;
                if (!has || d.prepare("SELECT count(*) n FROM users WHERE user_name <> ''' AND owner = 1").get().n) process.exit(0);
                const r = d.prepare("UPDATE users SET owner = 1 WHERE user_name = ?").run(process.env.OWNER);
                console.log("owner set:", r.changes);
              ''
            ];
          };
          controllers.actual.containers.actual = {
            image = pinned.images.actual-server;
            resources.requests = {
              cpu = "25m";
              memory = "272Mi";
            };
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
