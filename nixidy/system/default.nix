{
  imports = [
    ./cicd/argocd.nix
    ./cicd/descheduler.nix
    ./cicd/reloader.nix
    ./network/cilium.nix
    ./network/coredns.nix
    ./network/external-dns.nix
    ./network/cloudflared.nix
    ./observability/alertmanager.nix
    ./observability/grafana.nix
    ./observability/kube-state-metrics.nix
    ./observability/node-exporter.nix
    ./observability/prometheus.nix
    ./security/cert-manager.nix
    ./security/external-secrets
    ./storage/dragonflydb.nix
    ./storage/postgres.nix
    ./storage/rook-ceph.nix
    ./storage/volsync.nix
  ];
  nixidy.applications.namespaces = {
    namespace = "kube-system";
    annotations."argocd.argoproj.io/sync-wave" = "1";
    canivete.bootstrap.enable = true;
    resources.namespaces = {
      cicd = {};
      observability = {};
      security = {};
      storage = {};
    };
  };
}
