{
  imports = [
    ./cicd/app-of-apps.nix
    ./cicd/argo-events.nix
    ./cicd/argo-rollouts.nix
    ./cicd/argo-workflows.nix
    ./ai
    ./cicd/argocd.nix
    ./cicd/descheduler.nix
    ./cicd/harbor.nix
    ./cicd/reloader.nix
    ./mail/bulwark.nix
    ./mail/stalwart.nix
    ./network/cilium.nix
    ./network/coredns.nix
    ./network/adguard.nix
    ./network/external-dns.nix
    ./network/external-dns-internal.nix
    ./network/cloudflared.nix
    # STAGED — multus.nix documents its own prerequisites (NAD CRD
    # registration, home-lan NAD, RKE2/cilium CNI path adaptation, br0
    # verification) and cluster-wide CNI changes need separate testing.
    # #26 claimed this was TODO-commented but merged it active; restore
    # the documented staging until the prerequisites are done.
    # ./network/multus.nix
    ./network/tailscale.nix
    ./observability/alertmanager.nix
    ./observability/gatus.nix
    ./observability/grafana.nix
    ./observability/kube-state-metrics.nix
    ./observability/loki.nix
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
      ai = {};
      ai-sandbox = {};
      cicd = {};
      mail = {};
      observability = {};
      security = {};
      storage = {};
    };
  };
}
