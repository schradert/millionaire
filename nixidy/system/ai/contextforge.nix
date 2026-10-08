{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "mcp.${domain}";
in {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    # Keycloak OIDC client for ContextForge admin UI
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
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    gatus.endpoints.contextforge = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.contextforge = {
      namespace = "ai";
      postgres.enable = true;
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
              image.repository = "ghcr.io/ibm/mcp-context-forge";
              image.tag = "latest";
              env = {
                MCP_GATEWAY_PORT = "8080";
                MCP_GATEWAY_HOST = "0.0.0.0";
                DATABASE_URL = "postgres://contextforge:$(DB_PASSWORD)@contextforge-rw:5432/contextforge";
                OIDC_ISSUER_URL = "https://keycloak.${domain}/realms/default";
                OIDC_CLIENT_ID = "contextforge";
                OIDC_CLIENT_SECRET_ENV = "OIDC_CLIENT_SECRET";
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
          OIDC_CLIENT_SECRET = "{{ .oidc_secret }}";
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
