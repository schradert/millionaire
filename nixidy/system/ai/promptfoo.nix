{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "promptfoo.${domain}";
in {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    # Keycloak OIDC client for promptfoo dashboard
    applications.keycloak.resources.keycloakClients.promptfoo.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "promptfoo";
        name = "Promptfoo Eval Dashboard";
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/*"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    gatus.endpoints.promptfoo = {url = "https://${hostname}"; group = "internal";};
    applications.promptfoo = {
      namespace = "ai";
      helm.releases.promptfoo = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.promptfoo = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.promptfoo = {
              image.repository = "ghcr.io/promptfoo/promptfoo";
              image.tag = "latest";
              args = ["share" "--yes"];
              env = {
                PROMPTFOO_SHARE_STORE_TYPE = "sqlite";
                PROMPTFOO_SHARE_TTL = "0";
                OLLAMA_BASE_URL = "http://ollama.ai.svc.cluster.local:11434";
                OPENAI_BASE_URL = "http://bifrost.ai.svc.cluster.local:8000/v1";
              };
              envFrom = lib.toList {secretRef.name = "promptfoo";};
              ports = lib.toList {name = "http"; containerPort = 3000;};
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.promptfoo.ports.http.port = 3000;
          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "5Gi";
            globalMounts = lib.toList {path = "/root/.promptfoo";};
          };
        };
      };

      resources.httpRoutes.promptfoo.spec = {
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

      resources.externalSecrets.promptfoo.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data = {
          ANTHROPIC_API_KEY = "{{ .anthropic_key }}";
          OPENAI_API_KEY = "{{ .openai_key }}";
        };
        data = [
          {secretKey = "anthropic_key"; remoteRef.key = "ai/anthropic/api-key";}
          {secretKey = "openai_key"; remoteRef.key = "ai/openai/api-key";}
        ];
      };
    };

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://promptfoo.ai.svc.cluster.local:3000";
      namespace = "ai";
    };
  };
}
