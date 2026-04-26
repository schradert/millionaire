{config, ...}: {
  nixidy = {charts, lib, ...}: {
    applications.external-dns-internal = {
      namespace = "kube-system";
      resources.externalSecrets.external-dns-internal.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        data = lib.toList {
          secretKey = "ADGUARD_PASSWORD";
          remoteRef.key = "adguard/admin/password";
        };
      };
      helm.releases.external-dns-internal = {
        chart = charts.external-dns.external-dns;
        values = {
          fullnameOverride = "external-dns-internal";
          provider.name = "webhook";
          provider.webhook = {
            image.repository = "ghcr.io/muhlba91/external-dns-provider-adguard";
            image.tag = "v11.0.2";
            env = [
              {
                name = "ADGUARD_URL";
                # AdGuard Home on hyena VPS, reachable via tailscale operator sidecar
                # TODO: update with hyena's actual tailnet IP after headscale deployment
                value = "http://hyena:3000";
              }
              {
                name = "ADGUARD_USER";
                value = "admin";
              }
              {
                name = "ADGUARD_PASSWORD";
                valueFrom.secretKeyRef = {
                  name = "external-dns-internal";
                  key = "ADGUARD_PASSWORD";
                };
              }
              {
                name = "LOG_LEVEL";
                value = "info";
              }
              {
                name = "DRY_RUN";
                value = "false";
              }
            ];
            livenessProbe = {
              httpGet.path = "/healthz";
              httpGet.port = 8080;
              initialDelaySeconds = 10;
              periodSeconds = 10;
            };
            readinessProbe = {
              httpGet.path = "/healthz";
              httpGet.port = 8080;
              initialDelaySeconds = 5;
              periodSeconds = 10;
            };
          };
          extraArgs = [
            "--gateway-name=internal"
            "--annotation-filter=external-dns.alpha.kubernetes.io/exclude notin (true)"
          ];
          policy = "sync";
          sources = ["gateway-httproute"];
          txtOwnerId = "internal";
          txtPrefix = "k8s-internal.";
          logFormat = "json";
          domainFilters = [config.canivete.meta.domain];
          serviceMonitor.enabled = true;
          podAnnotations."reloader.stakater.com/auto" = "true";
        };
      };
    };
  };
}
