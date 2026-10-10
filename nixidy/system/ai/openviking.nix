{config, ...}: let
  inherit (config.canivete.meta) domain;
  port = 1933;
  # Bifrost is the only LLM provider: OpenAI-compatible, models addressed as <provider>/<model>.
  # Inference needs no key (enforce_governance_header = false); the SDKs just need a non-empty one.
  bifrost = {
    api_base = "http://bifrost.ai.svc.cluster.local:8000/v1";
    api_key = "bifrost";
  };
in {
  nixidy = {
    lib,
    charts,
    ...
  }: {
    applications.openviking = {
      namespace = "ai";
      # Root key for the server API and the /mcp endpoint; referenced from ov.conf as ${OPENVIKING_ROOT_API_KEY}.
      generatedSecrets.openviking-root-api-key = {
        key = "OPENVIKING_ROOT_API_KEY";
        length = 48;
      };
      helm.releases.openviking = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.openviking = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.openviking = {
              image = {
                repository = "ghcr.io/volcengine/openviking";
                tag = "v0.5.0";
                digest = "sha256:c60a83cd79cfce80db5266acb8bdd0908eee8abe8ff559a5f786aa504c251ccf";
              };
              env = {
                # VikingBot is optional and needs its own config
                OPENVIKING_WITH_BOT = "0";
                OPENVIKING_SERVER_PORT = toString port;
              };
              envFrom = lib.toList {secretRef.name = "openviking-root-api-key";};
              ports = lib.toList {
                name = "http";
                containerPort = port;
              };
              resources = {
                requests = {
                  cpu = "250m";
                  memory = "1Gi";
                };
                limits.memory = "4Gi";
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
          service.openviking.ports.http.port = port;
          persistence = {
            data = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "10Gi";
              advancedMounts.openviking.openviking = [{path = "/app/.openviking";}];
            };
            config = {
              type = "configMap";
              name = "openviking";
              advancedMounts.openviking.openviking = [
                {
                  path = "/app/.openviking/ov.conf";
                  subPath = "ov.conf";
                  readOnly = true;
                }
              ];
            };
          };
          configMaps.openviking.data."ov.conf" = builtins.toJSON {
            server = {
              host = "0.0.0.0";
              inherit port;
              auth_mode = "api_key";
              root_api_key = "\${OPENVIKING_ROOT_API_KEY}";
            };
            storage = {
              workspace = "/app/.openviking/data";
              vectordb = {
                name = "context";
                backend = "local";
              };
              agfs.backend = "local";
            };
            embedding.dense =
              bifrost
              // {
                provider = "openai";
                model = "openai/text-embedding-3-small";
                dimension = 1536;
              };
            vlm =
              bifrost
              // {
                provider = "openai";
                model = "openai/gpt-4.1-mini";
              };
          };
        };
      };
      # Idempotent post-sync bootstrap (apps/app-bootstrap): the root key gets 403 on MCP
      # tools/list, so create a non-root agent user and mirror its key into the
      # openviking-agent-key Secret. Never logs the key. Reruns must stay a no-op.
      resources.serviceAccounts.openviking-bootstrap = {};
      resources.roles.openviking-bootstrap.rules = [
        {
          apiGroups = [""];
          resources = ["secrets"];
          verbs = ["create"];
        }
        {
          apiGroups = [""];
          resources = ["secrets"];
          resourceNames = ["openviking-agent-key"];
          verbs = ["get" "patch"];
        }
      ];
      resources.roleBindings.openviking-bootstrap = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = "openviking-bootstrap";
        };
        subjects = lib.toList {
          kind = "ServiceAccount";
          name = "openviking-bootstrap";
          namespace = "ai";
        };
      };
      resources.jobs.openviking-bootstrap = {
        metadata.annotations = {
          "argocd.argoproj.io/hook" = "PostSync";
          "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
        };
        spec = {
          backoffLimit = 6;
          activeDeadlineSeconds = 1200;
          template.spec = {
            restartPolicy = "OnFailure";
            serviceAccountName = "openviking-bootstrap";
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = lib.toList {
              name = "bootstrap";
              image = "harbor.${domain}/library/app-bootstrap:0.2.0";
              args = ["openviking"];
              env = [
                {
                  name = "OPENVIKING_URL";
                  value = "http://openviking.ai.svc.cluster.local:${toString port}";
                }
                {
                  name = "ROOT_API_KEY_FILE";
                  value = "/secrets/root/OPENVIKING_ROOT_API_KEY";
                }
              ];
              volumeMounts = lib.toList {
                name = "root";
                mountPath = "/secrets/root";
                readOnly = true;
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = ["ALL"];
              };
            };
            volumes = lib.toList {
              name = "root";
              secret.secretName = "openviking-root-api-key";
            };
          };
        };
      };

      # No external route: internal only. Agents reach it at http://openviking.ai.svc.cluster.local:1933/mcp
      # (Bearer <root key>), e.g. registered as an MCP gateway in contextforge.
    };
  };
}
