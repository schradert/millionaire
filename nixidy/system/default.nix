{
  imports = [
    ./cicd/argocd.nix
    ./network/cilium.nix
    ./network/coredns.nix
    ./network/external-dns.nix
    ./network/cloudflared.nix
    ./security/cert-manager.nix
    ./security/external-secrets
    ./storage/dragonflydb.nix
  ];
  nixidy.applications.namespaces = {
    namespace = "kube-system";
    annotations."argocd.argoproj.io/sync-wave" = "4";
    canivete.bootstrap.enable = true;
    resources.namespaces = {
      cicd = {};
      security = {};
      storage = {};
    };
  };
}
