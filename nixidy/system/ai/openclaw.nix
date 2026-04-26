# OpenClaw: multi-channel AI messaging gateway (Discord only initially)
# Deployed in isolated ai-sandbox namespace with strict NetworkPolicy
{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    applications.openclaw = {
      namespace = "ai-sandbox";
      helm.releases.openclaw = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.openclaw = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.openclaw = {
              # TODO: update image once published, or build from github:openclaw/openclaw
              image.repository = "ghcr.io/openclaw/openclaw";
              image.tag = "latest";
              env = {
                GATEWAY_HOST = "0.0.0.0";
                GATEWAY_PORT = "18789";
                # Connect to Bifrost for LLM routing
                LLM_BASE_URL = "http://bifrost.ai.svc.cluster.local:8000/v1";
                # Connect to ContextForge for MCP tools
                MCP_GATEWAY_URL = "http://contextforge.ai.svc.cluster.local:8080";
                # DM pairing mode — unknown senders get pairing codes
                DM_PAIRING_MODE = "true";
                # Disable all device actions for safety
                ALLOW_DEVICE_ACTIONS = "false";
              };
              envFrom = lib.toList {secretRef.name = "openclaw";};
              ports = lib.toList {name = "ws"; containerPort = 18789;};
            };
          };
          service.openclaw.ports.ws.port = 18789;
        };
      };

      # Strict NetworkPolicy — only allow essential egress
      resources.networkPolicies.openclaw-egress.spec = {
        podSelector.matchLabels."app.kubernetes.io/name" = "openclaw";
        policyTypes = ["Egress"];
        egress = [
          # DNS
          {
            ports = [{port = 53; protocol = "UDP";} {port = 53; protocol = "TCP";}];
          }
          # Bifrost (LLM gateway) in ai namespace
          {
            to = [{namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "ai";}];
            ports = [{port = 8000; protocol = "TCP";}];
          }
          # ContextForge (MCP gateway) in ai namespace
          {
            to = [{namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "ai";}];
            ports = [{port = 8080; protocol = "TCP";}];
          }
          # Discord API (external HTTPS)
          {
            ports = [{port = 443; protocol = "TCP";}];
            to = [{ipBlock.cidr = "0.0.0.0/0";}];
          }
        ];
      };

      # ResourceQuota to prevent runaway agents
      resources.resourceQuotas.openclaw-limits.spec.hard = {
        "requests.cpu" = "2";
        "requests.memory" = "4Gi";
        "limits.cpu" = "4";
        "limits.memory" = "8Gi";
        pods = "5";
      };

      resources.externalSecrets.openclaw.spec.data = lib.toList {
        secretKey = "DISCORD_BOT_TOKEN";
        remoteRef.key = "ai/openclaw/discord-token";
        sourceRef.storeRef.name = "bitwarden";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
    };
  };
}
