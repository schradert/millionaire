{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {
    charts,
    lib,
    pulumi,
    ...
  }: let
    tunnel_id = pulumi.vals "cloudflare:index/zeroTrustTunnelCloudflared:ZeroTrustTunnelCloudflared" "main" "id";
    subdomain = "external.${domain}";
    gateway = "https://cilium-gateway-external.kube-system.svc.cluster.local";
    credsPath = "/etc/cloudflared/token.txt";
    configPath = "/etc/cloudflared/config.yaml";
    port = 8080;
    probe = {
      enabled = true;
      custom = true;
      spec = {
        httpGet.path = "/ready";
        httpGet.port = port;
        initialDelaySeconds = 0;
        periodSeconds = 10;
        timeoutSeconds = 1;
        failureThreshold = 3;
      };
    };
  in {
    applications.cloudflared = {
      namespace = "kube-system";
      resources.externalSecrets.cloudflared.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        data = lib.toList {
          secretKey = "token.txt";
          remoteRef.key = "cloudflare/tunnel/token";
        };
      };
      resources.dnsEndpoints.cloudflared-tunnel.spec.endpoints = lib.toList {
        dnsName = subdomain;
        recordType = "CNAME";
        targets = ["${tunnel_id}.cfargotunnel.com"];
      };
      helm.releases.cloudflared = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.cloudflared = {
            strategy = "RollingUpdate";
            annotations."reloader.stakater.com/auto" = "true";
            containers.cloudflared = {
              image.repository = "cloudflare/cloudflared";
              image.tag = "2026.2.0@sha256:d4d2bf56c792ab207fa557c2431c250bfc8e4114d7e28c98eda1896bf65f10f6";
              args = ["tunnel" "--config" configPath "run"];
              probes.liveness = probe;
              probes.readiness = probe;
              probes.startup = lib.recursiveUpdate probe {spec.failureThreshold = 30;};
            };
          };
          service.cloudflared.controller = "cloudflared";
          service.cloudflared.ports.http.port = port;
          configMaps.cloudflared.data."config.yaml" = builtins.toJSON {
            tunnel = tunnel_id;
            token-file = credsPath;
            no-autoupdate = true;
            metrics = "0.0.0.0:8080";
            originRequest.originServerName = subdomain;
            ingress = [
              {
                hostname = domain;
                service = gateway;
              }
              {
                hostname = "*.${domain}";
                service = gateway;
              }
              {service = "http_status:404";}
            ];
          };
          persistence.config = {
            type = "configMap";
            name = "cloudflared";
            globalMounts = lib.toList {
              path = configPath;
              subPath = "config.yaml";
              readOnly = true;
            };
          };
          persistence.creds = {
            type = "secret";
            name = "cloudflared";
            globalMounts = lib.toList {
              path = credsPath;
              subPath = "token.txt";
              readOnly = true;
            };
          };
          serviceMonitor.cloudflared.serviceName = "cloudflared";
          serviceMonitor.cloudflared.endpoints = lib.toList {
            port = "http";
            scheme = "http";
            path = "/metrics";
            interval = "1m";
            scrapeTimeout = "30s";
          };
        };
      };
    };
  };
}
