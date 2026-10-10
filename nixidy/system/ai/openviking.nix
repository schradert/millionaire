{...}: let
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
      # No external route: internal only. Agents reach it at http://openviking.ai.svc.cluster.local:1933/mcp
      # (Bearer <root key>), e.g. registered as an MCP gateway in contextforge.
    };
  };
}
