{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    chart = charts.external-dns.external-dns;
  in {
    applications.external-dns-crds.namespace = "kube-system";
    canivete.crds.external-dns = {
      application = "external-dns-crds";
      install = true;
      src = chart;
      prefix = "crds";
    };
    applications.external-dns = {
      namespace = "kube-system";
      resources.externalSecrets.external-dns.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        data = lib.toList {
          secretKey = "token";
          remoteRef.key = "cloudflare/account/token";
        };
      };
      helm.releases.external-dns = {
        inherit chart;
        values = {
          provider.name = "cloudflare";
          env = lib.toList {
            name = "CF_API_TOKEN";
            valueFrom.secretKeyRef = {
              name = "external-dns";
              key = "token";
            };
          };
          extraArgs = [
            "--cloudflare-dns-records-per-page=1000"
            "--crd-source-apiversion=externaldns.k8s.io/v1alpha1"
            "--crd-source-kind=DNSEndpoint"
            "--gateway-name=external"
            "--cloudflare-proxied"
          ];
          policy = "sync";
          sources = ["crd" "gateway-httproute"];
          txtOwnerId = "main";
          txtPrefix = "k8s.";
          logFormat = "json";
          domainFilters = [config.canivete.meta.domain];
          serviceMonitor.enabled = true;
          podAnnotations."reloader.stakater.com/auto" = "true";
        };
      };
    };
  };
}
