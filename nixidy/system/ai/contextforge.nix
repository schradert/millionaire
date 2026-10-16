{config, ...}: let
  inherit (config.canivete.meta) domain people;
  hostname = "mcp.${domain}";
  issuer = "https://keycloak.${domain}/realms/default";
  # Virtual server with every registered MCP server's tools, at /servers/<id>/mcp; the
  # same id is in modules/opencode.nix.
  serverId = "05238f180ea94c7c8c5621976aec4604";
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: {
    # Keycloak SSO for the admin UI (SSO_KEYCLOAK_*); members of `admin` become platform admins.
    applications.keycloak.resources.keycloakClients.contextforge.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "contextforge";
        create = true;
      };
      definition = {
        clientId = "contextforge";
        name = "ContextForge MCP Gateway";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/*"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };

    portal.apps.contextforge.groups = ["admin"];
    gatus.endpoints.contextforge = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.contextforge = {
      namespace = "ai";
      postgres.enable = true;
      postgres.instances = 2;
      postgres.avoidNodes = ["sirver"];
      # The gateway rejects placeholder secrets at startup.
      generatedSecrets = {
        contextforge-jwt = {
          key = "JWT_SECRET_KEY";
          length = 48;
        };
        contextforge-auth-encryption = {
          key = "AUTH_ENCRYPTION_SECRET";
          length = 48;
        };
        # Password fields must be at least 12 characters (22 for privileged).
        contextforge-basic-auth = {
          key = "BASIC_AUTH_PASSWORD";
          length = 24;
        };
        contextforge-admin = {
          key = "PLATFORM_ADMIN_PASSWORD";
          length = 24;
          bitwarden = "contextforge/admin-password";
        };
        contextforge-default-user = {
          key = "DEFAULT_USER_PASSWORD";
          length = 24;
        };
      };
      helm.releases.contextforge = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.contextforge = {
            annotations."reloader.stakater.com/auto" = "true";
            # The image needs x86-64-v3; octopus (Xeon E5-2670, Sandy Bridge) lacks it.
            pod.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = lib.toList {
              matchExpressions = lib.toList {
                key = "kubernetes.io/hostname";
                operator = "NotIn";
                values = ["octopus"];
              };
            };
            containers.contextforge = {
              image = pinned.images.mcp-context-forge;
              env = {
                # The gateway's settings read HOST/PORT (default 127.0.0.1:4444);
                # MCP_GATEWAY_* are ignored, so without these the probes on :8080
                # get connection refused.
                HOST = "0.0.0.0";
                PORT = "8080";
                DATABASE_URL = "postgresql+psycopg://contextforge:$(DB_PASSWORD)@contextforge-rw:5432/contextforge";
                # SSO redirects and virtual server URLs.
                APP_DOMAIN = "https://${hostname}";
                # Keycloak login for the UI; the provider row is (re)created at startup.
                # SSO_KEYCLOAK_CLIENT_SECRET comes from the `contextforge` Secret.
                SSO_ENABLED = "true";
                SSO_KEYCLOAK_ENABLED = "true";
                SSO_KEYCLOAK_BASE_URL = "https://keycloak.${domain}";
                SSO_KEYCLOAK_REALM = "default";
                SSO_KEYCLOAK_CLIENT_ID = "contextforge";
                SSO_KEYCLOAK_ROLE_MAPPINGS = builtins.toJSON {admin = "platform_admin";};
                # Keycloak access tokens (sso-token) as API/MCP bearer credentials; the bootstrap
                # marks the provider trusted with audience oauth2-proxy.
                SSO_API_TOKEN_AUTH_ENABLED = "true";
                # The bootstrap creates tristan as a local user; his first Keycloak login relinks it.
                SSO_ALLOW_PROVIDER_LINKING = "true";
                # Gateways are cluster Services; SSRF protection blocks private ranges by default (422).
                SSRF_ALLOWED_NETWORKS = builtins.toJSON ["10.43.0.0/16"];
                # ToolHive vMCP as upstream MCP source
                TOOLHIVE_VMCP_URL = "http://homelab-vmcp.ai.svc.cluster.local:8080";
              };
              envFrom = map (name: {secretRef = {inherit name;};}) [
                "contextforge"
                "contextforge-jwt"
                "contextforge-auth-encryption"
                "contextforge-basic-auth"
                "contextforge-admin"
                "contextforge-default-user"
              ];
              ports = lib.toList {
                name = "http";
                containerPort = 8080;
              };
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health";
                spec.httpGet.port = "http";
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health";
                spec.httpGet.port = "http";
              };
              probes.startup = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health";
                spec.httpGet.port = "http";
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };
          service.contextforge.ports.http.port = 8080;
        };
      };

      # Idempotent post-sync bootstrap (apps/app-bootstrap): register OpenViking as an MCP
      # gateway (Bearer = the agent key from the openviking-bootstrap job). With the
      # app-bootstrap-contextforge image (>= 0.18.0) also: the OAuth virtual server `homelab`
      # (every tool, resource and prompt; Keycloak tokens with audience oauth2-proxy), the
      # keycloak provider trusted for API tokens, and tristan as an admin user (OAuth virtual
      # servers only serve users already in the database). Reruns are a no-op.
      bootstrap = {
        image = with (pinned.images.app-bootstrap-contextforge or pinned.images.app-bootstrap); "${repository}:${tag}@${digest}";
        args = ["contextforge"];
        env =
          {
            CONTEXTFORGE_URL = "http://contextforge.ai.svc.cluster.local:8080";
            ADMIN_PASSWORD_FILE = "/secrets/admin/PLATFORM_ADMIN_PASSWORD";
            UPSTREAM_TOKEN_FILE = "/secrets/openviking/OPENVIKING_AGENT_API_KEY";
            GATEWAY_URL = "http://openviking.ai.svc.cluster.local:1933/mcp";
          }
          // lib.optionalAttrs (pinned.images ? app-bootstrap-contextforge) {
            SERVER_ID = serverId;
            OIDC_ISSUER = issuer;
            OIDC_AUDIENCE = "oauth2-proxy";
            USER_EMAIL = people.my.profiles.personal.email;
          };
        secrets = {
          admin = "contextforge-admin";
          openviking = "openviking-agent-key";
        };
      };

      resources.httpRoutes.contextforge.spec = {
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

      resources.externalSecrets.contextforge.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data = {
          DB_PASSWORD = "{{ .db_password }}";
          SSO_KEYCLOAK_CLIENT_SECRET = "{{ .oidc_secret }}";
        };
        data = [
          {
            secretKey = "db_password";
            remoteRef.key = "contextforge-app";
            remoteRef.property = "password";
            sourceRef.storeRef.name = "kubernetes-ai";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "oidc_secret";
            remoteRef.key = "contextforge";
            remoteRef.property = "client-secret";
            sourceRef.storeRef.name = "kubernetes-identity";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
      };
    };

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://contextforge.ai.svc.cluster.local:8080";
      namespace = "ai";
    };
  };
}
