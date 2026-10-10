{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "chat.${domain}";
in {
  nixidy = {
    charts,
    lib,
    pinned,
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
      clientSecretRef = {
        name = "librechat";
        create = true;
      };
      definition = {
        clientId = "librechat";
        name = "LibreChat";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/oauth/openid/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    gatus.endpoints.librechat = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.librechat = {
      namespace = "ai";
      # Uploads/avatars plus the MongoDB data (crash-consistent copy of the live files).
      volsync.pvcs.librechat = {
        title = "librechat";
        restore = false;
      };
      volsync.pvcs.librechat-mongodb = {
        title = "data-librechat-mongodb-0";
        restore = false;
      };
      # LibreChat parses the creds key/IV as hex (32 and 16 bytes), hence digits only.
      generatedSecrets = {
        librechat-creds-key = {
          key = "CREDS_KEY";
          length = 64;
          numeric = true;
        };
        librechat-creds-iv = {
          key = "CREDS_IV";
          length = 32;
          numeric = true;
        };
        librechat-jwt = {
          key = "JWT_SECRET";
          length = 64;
        };
      };
      helm.releases.librechat = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.librechat = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.librechat = {
              image = pinned.images.librechat;
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
                MONGO_URI = "mongodb://librechat-librechat-mongodb:27017/librechat";
              };
              envFrom = [
                {secretRef.name = "librechat";}
                {secretRef.name = "librechat-creds-key";}
                {secretRef.name = "librechat-creds-iv";}
                {secretRef.name = "librechat-jwt";}
              ];
              ports = lib.toList {
                name = "http";
                containerPort = 3080;
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
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };
          controllers.mongodb = {
            type = "statefulset";
            containers.mongodb = {
              image = pinned.images.mongo;
              ports = lib.toList {
                name = "mongodb";
                containerPort = 27017;
              };
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

      # OIDC client secret from the keycloak-operator
      resources.externalSecrets.librechat.spec = {
        secretStoreRef.name = "kubernetes-identity";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data.OPENID_CLIENT_SECRET = "{{ .oidc_secret }}";
        data = lib.toList {
          secretKey = "oidc_secret";
          remoteRef.key = "librechat";
          remoteRef.property = "client-secret";
        };
      };
    };

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://librechat.ai.svc.cluster.local:3080";
      namespace = "ai";
    };
  };
}
