{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "chat.${domain}";
in {
  nixidy = {
    charts,
    lib,
    pkgs,
    ...
  }: let
    yaml = pkgs.formats.yaml {};
    toYAML = name: obj: builtins.readFile (yaml.generate name obj);

    librechatConfig = {
      version = "1.2.1";
      cache = true;
      registration = {
        socialLogins = ["openid"];
        allowedDomains = [domain];
      };
      endpoints = {
        custom = [
          {
            name = "Homelab";
            apiKey = "\${BIFROST_API_KEY}";
            baseURL = "http://bifrost.ai.svc.cluster.local:8000/v1";
            models = {
              default = ["mistral:7b" "codellama:7b" "mistralai/Mistral-7B-Instruct-v0.3"];
              fetch = true;
            };
            titleConvo = true;
            titleModel = "mistral:7b";
            dropParams = ["stop" "user"];
          }
        ];
      };
      mcpServers = {
        contextforge = {
          type = "streamable-http";
          url = "http://contextforge.ai.svc.cluster.local:8080/mcp";
        };
      };
    };
  in {
    # Keycloak OIDC client for LibreChat
    applications.keycloak.resources.keycloakClients.librechat.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "librechat";
        name = "LibreChat";
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/oauth/openid/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    gatus.endpoints.librechat = {url = "https://${hostname}"; group = "internal";};
    applications.librechat = {
      namespace = "ai";
      helm.releases.librechat = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.librechat = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.librechat = {
              image.repository = "ghcr.io/danny-avila/librechat";
              image.tag = "v0.7.70";
              env = {
                HOST = "0.0.0.0";
                PORT = "3080";
                ALLOW_REGISTRATION = "false";
                ALLOW_SOCIAL_LOGIN = "true";
                ALLOW_SOCIAL_REGISTRATION = "true";
                OPENID_ISSUER = "https://keycloak.${domain}/realms/default";
                OPENID_CLIENT_ID = "librechat";
                OPENID_CALLBACK_URL = "https://${hostname}/oauth/openid/callback";
                OPENID_SCOPE = "openid profile email";
                OPENID_BUTTON_LABEL = "Login with Keycloak";
                MONGO_URI = "mongodb://librechat-mongodb:27017/librechat";
              };
              envFrom = lib.toList {secretRef.name = "librechat";};
              ports = lib.toList {name = "http"; containerPort = 3080;};
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/api/health";
                spec.httpGet.port = "http";
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/api/health";
                spec.httpGet.port = "http";
              };
              probes.startup.enabled = true;
            };
          };
          controllers.mongodb = {
            type = "statefulset";
            containers.mongodb = {
              image.repository = "mongo";
              image.tag = "7";
              ports = lib.toList {name = "mongodb"; containerPort = 27017;};
            };
            statefulset.volumeClaimTemplates = lib.toList {
              name = "data";
              accessMode = "ReadWriteOnce";
              size = "10Gi";
              globalMounts = lib.toList {path = "/data/db";};
            };
          };
          service.librechat = {
            controller = "librechat";
            ports.http.port = 3080;
          };
          service.librechat-mongodb = {
            controller = "mongodb";
            ports.mongodb.port = 27017;
          };
          configMaps.librechat.data."librechat.yaml" = toYAML "librechat.yaml" librechatConfig;
          persistence = {
            config = {
              type = "configMap";
              name = "librechat";
              advancedMounts.librechat.librechat = lib.toList {
                path = "/app/librechat.yaml";
                subPath = "librechat.yaml";
                readOnly = true;
              };
            };
            uploads = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "5Gi";
              advancedMounts.librechat.librechat = lib.toList {path = "/app/client/public/images";};
            };
          };
        };
      };

      resources.httpRoutes.librechat.spec = {
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

      resources.externalSecrets.librechat.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data = {
          CREDS_KEY = "{{ .session_secret }}";
          CREDS_IV = "{{ .session_iv }}";
          JWT_SECRET = "{{ .jwt_secret }}";
          OPENID_CLIENT_SECRET = "{{ .oidc_secret }}";
        };
        data = [
          {secretKey = "session_secret"; remoteRef.key = "ai/librechat/session-secret";}
          {secretKey = "session_iv"; remoteRef.key = "ai/librechat/session-iv";}
          {secretKey = "jwt_secret"; remoteRef.key = "ai/librechat/jwt-secret";}
          {
            secretKey = "oidc_secret";
            # TODO: switch to keycloak-operator synced secret once available
            remoteRef.key = "ai/librechat/client-secret";
          }
        ];
      };
    };

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://librechat.ai.svc.cluster.local:3080";
      namespace = "ai";
    };
  };
}
