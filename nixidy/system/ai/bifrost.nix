{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "bifrost.${domain}";
in {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    providerKey = name: env: {
      inherit name;
      value = "env.${env}";
      models = ["*"];
      weight = 1;
    };
  in {
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

    gatus.endpoints.bifrost = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.bifrost = {
      namespace = "ai";
      helm.releases.bifrost = {
        chart = pinned.charts.bifrost;
        values = {
          replicaCount = 1;
          # Chart 1.5.0 ships appVersion 1.5.0; the old v1.3.36 tag predates its config schema
          image.tag = "v1.5.0";
          service.port = 8000;
          # Provider keys come from the bifrost Secret (Bitwarden); the Secret is optional
          # so the gateway starts before the keys exist.
          bifrost.providers = {
            openai.keys = lib.toList (providerKey "openai" "OPENAI_API_KEY");
            anthropic.keys = lib.toList (providerKey "anthropic" "ANTHROPIC_API_KEY");
            gemini.keys = lib.toList (providerKey "gemini" "GOOGLE_API_KEY");
          };
          podAnnotations."reloader.stakater.com/auto" = "true";
          envFrom = lib.toList {
            secretRef = {
              name = "bifrost";
              optional = true;
            };
          };
        };
      };

      # The ReadWriteOnce data PVC can't be shared by old and new pods during a rollout.
      # SSA can't drop the API-defaulted rollingUpdate block when switching to Recreate
      # (rendering `rollingUpdate = null` omits it), so sync this Deployment with replace.
      resources.deployments.bifrost = {
        metadata.annotations."argocd.argoproj.io/sync-options" = "Replace=true";
        spec.strategy.type = "Recreate";
      };

      # The dashboard (:8000/) is only reachable via oauth2-proxy (Keycloak): Bifrost's
      # own OIDC/SSO is enterprise-only. In-cluster clients call bifrost.ai.svc:8000 directly.
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
