{
  imports = [
    ./cicd/argocd.nix
    ./network/cilium.nix
    ./network/coredns.nix
    ./security/cert-manager.nix
    ./storage/dragonflydb.nix
  ];
  nixidy.applications.namespaces = {
    namespace = "kube-system";
    canivete.bootstrap.enable = true;
    resources.namespaces = {
      cicd = {};
      security = {};
      storage = {};
    };
  };
}
