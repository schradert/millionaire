{
  imports = [
    ./cicd/argocd.nix
    ./network/cilium.nix
    ./network/coredns.nix
    ./network/external-dns.nix
    ./network/cloudflared.nix
    ./observability/prometheus.nix
    ./security/cert-manager.nix
    ./security/external-secrets
    ./storage/dragonflydb.nix
  ];
  nixidy.applications.namespaces = {
    namespace = "kube-system";
    annotations."argocd.argoproj.io/sync-wave" = "3";
    canivete.bootstrap.enable = true;
    resources.namespaces = {
      cicd = {};
      observability = {};
      security = {};
      storage = {};
    };
  };
}
