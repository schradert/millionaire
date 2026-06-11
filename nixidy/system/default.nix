{
  imports = [
    ./cicd/app-of-apps.nix
    ./cicd/argo-events.nix
    ./cicd/argo-rollouts.nix
    ./cicd/argo-workflows.nix
    ./ai
    ./cicd/argocd.nix
    ./cicd/capi-operator.nix
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
    # multus is re-staged (its header always said "intentionally not yet
    # imported"; it was never rendered into generated/ or deployed). Upstream
    # re-published the 7.0.0 tarball with bjw-s common 5.x, which breaks
    # rendering until controllers pin serviceAccount — fix when actually
    # staging it together with music-assistant's NAD.
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
