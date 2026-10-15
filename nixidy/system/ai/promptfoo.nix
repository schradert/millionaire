{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "promptfoo.${domain}";
  # AI provider keys are user-supplied (Bitwarden `ai/{anthropic,openai}/api-key`, see
  # docs/manual-steps.md). Until then there is no ExternalSecret and the Secret is optional.
  providerKeys = false;
in {
  nixidy = {
    charts,
    lib,
    pinned,
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

    portal.apps.promptfoo.groups = ["admin"];
    gatus.endpoints.promptfoo = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.promptfoo = {
      namespace = "ai";
      volsync.pvcs.promptfoo = {
        title = "promptfoo";
        restore = false;
      };
      helm.releases.promptfoo = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.promptfoo = {
            annotations."reloader.stakater.com/auto" = "true";
            # The image runs as promptfoo (uid 100, gid 101): data under its home, not /root (0700).
            pod.securityContext = {
              fsGroup = 101;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.promptfoo = {
              image = pinned.images.promptfoo;
              # The image's default command serves the web UI on :3000.
              env = {
                PROMPTFOO_CONFIG_DIR = "/home/promptfoo/.promptfoo";
                PROMPTFOO_SHARE_STORE_TYPE = "sqlite";
                PROMPTFOO_SHARE_TTL = "0";
                OLLAMA_BASE_URL = "http://ollama.ai.svc.cluster.local:11434";
                OPENAI_BASE_URL = "http://bifrost.ai.svc.cluster.local:8000/v1";
              };
              envFrom = lib.toList {
                secretRef = {
                  name = "promptfoo";
                  optional = true;
                };
              };
              ports = lib.toList {
                name = "http";
                containerPort = 3000;
              };
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
            globalMounts = lib.toList {path = "/home/promptfoo/.promptfoo";};
          };
        };
      };

      # RWO data PVC: a rolling update's new pod can't attach it on another node.
      resources.deployments.promptfoo = {
        metadata.annotations."argocd.argoproj.io/sync-options" = "Replace=true";
        spec.strategy.type = lib.mkForce "Recreate";
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

      resources.externalSecrets.promptfoo = lib.mkIf providerKeys {
        spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.template.data = {
            ANTHROPIC_API_KEY = "{{ .anthropic_key }}";
            OPENAI_API_KEY = "{{ .openai_key }}";
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
          ];
        };
      };
    };

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://promptfoo.ai.svc.cluster.local:3000";
      namespace = "ai";
    };
  };
}
