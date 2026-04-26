{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "bifrost.${domain}";
in {
  nixidy = {lib, ...}: {
    # Keycloak OIDC client for Bifrost dashboard
    applications.keycloak.resources.keycloakClients.bifrost.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "bifrost";
        name = "Bifrost LLM Gateway";
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/*"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    gatus.endpoints.bifrost = {url = "https://${hostname}"; group = "internal";};
    applications.bifrost = {
      namespace = "ai";
      helm.releases.bifrost = {
        chart = lib.helm.downloadHelmChart {
          chart = "bifrost";
          version = "1.5.0";
          repo = "https://maximhq.github.io/bifrost/helm-charts";
          chartHash = "sha256-Dwbis8l61YZUo4dRLlBpnGBt9kXpAOsRT441hG18Y2c=";
        };
        values = {
          replicaCount = 1;
          image.tag = "v1.3.36";
          service.port = 8000;
          config = {
            providers = {
              ollama = {
                type = "ollama";
                base_url = "http://ollama.ai.svc.cluster.local:11434";
              };
              vllm = {
                type = "openai";
                base_url = "http://vllm.ai.svc.cluster.local:8000/v1";
              };
              anthropic = {
                type = "anthropic";
                api_key_env = "ANTHROPIC_API_KEY";
              };
              openai = {
                type = "openai";
                api_key_env = "OPENAI_API_KEY";
              };
              google = {
                type = "google";
                api_key_env = "GOOGLE_API_KEY";
              };
            };
            routing = {
              default_provider = "ollama";
              fallback_order = ["ollama" "vllm" "anthropic" "openai"];
            };
          };
          envFrom = lib.toList {secretRef.name = "bifrost";};
        };
      };

      resources.httpRoutes.bifrost.spec = {
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

      resources.externalSecrets.bifrost.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data = {
          ANTHROPIC_API_KEY = "{{ .anthropic_key }}";
          OPENAI_API_KEY = "{{ .openai_key }}";
          GOOGLE_API_KEY = "{{ .google_key }}";
        };
        data = [
          {
            secretKey = "anthropic_key";
            remoteRef.key = "ai/anthropic/api-key";
          }
          {
            secretKey = "openai_key";
            remoteRef.key = "ai/openai/api-key";
          }
          {
            secretKey = "google_key";
            remoteRef.key = "ai/google/api-key";
          }
        ];
      };
    };

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://bifrost.ai.svc.cluster.local:8000";
      namespace = "ai";
    };
  };
}
