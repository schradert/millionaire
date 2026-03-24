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
                value = "http://adguard.kube-system.svc.cluster.local:3000";
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
          # NOTE: --default-targets overrides the gateway's external-dns target annotation
          # (internal.trdos.me) with the actual LAN IP. Without this, external-dns creates
          # CNAME records (firefly.trdos.me → internal.trdos.me), but AdGuard Home doesn't
          # resolve CNAME targets against its own local rewrites — it goes upstream instead.
          # See: https://github.com/AdguardTeam/AdGuardHome/issues/3350
          extraArgs = [
            "--gateway-name=internal"
            "--default-targets=192.168.50.241"
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
