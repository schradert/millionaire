{
  imports = [
    ./cicd/app-of-apps.nix
    ./cicd/argo-events.nix
    ./cicd/argo-rollouts.nix
    ./cicd/argo-workflows.nix
    ./ai
    ./cicd/argocd.nix
    # STAGED — cloud-burst CAPI autoscaling. The modules are complete and
    # render, but activating them needs prerequisites NOT yet done: a
    # dedicated Hetzner "millionaire-capi" project + token (pulumi config
    # set --secret hcloudCapiToken), the cloud-worker snapshot uploaded, and
    # a cross-site datapath spike. Deploying them now would stand up CAPI
    # controllers that can't provision (no token/image) and is untested infra.
    # Uncomment all three together once the prerequisites are met + tested
    # (see docs/cloud-burst.md and project_cloud_burst_capi memory).
    # ./cicd/capi-cluster.nix
    # ./cicd/capi-operator.nix
    # ./cicd/cluster-autoscaler.nix
    ./cicd/bootstrap.nix
    ./cicd/descheduler.nix
    ./cicd/harbor.nix
    ./cicd/reloader.nix
    ./cluster/generic-device-plugin.nix
    ./cluster/k8tz.nix
    ./cluster/medik8s.nix
    ./mail/bulwark.nix
    ./mail/stalwart.nix
    ./network/cilium.nix
    ./network/coredns.nix
    ./network/external-dns.nix
    ./network/external-dns-internal.nix
    ./network/lan-dns.nix
    ./network/cloudflared.nix
    ./network/multus.nix
    ./network/netpol.nix
    ./observability/alert-digest.nix
    ./observability/alertmanager.nix
    ./observability/alloy.nix
    ./observability/dashboards.nix
    ./observability/faro-sdk.nix
    ./observability/gatus.nix
    ./observability/grafana.nix
    ./observability/kube-state-metrics.nix
    ./observability/loki.nix
    ./observability/mimir.nix
    ./observability/node-exporter.nix
    ./observability/ntfy.nix
    ./observability/prometheus.nix
    ./observability/pyroscope.nix
    ./observability/smartctl-exporter.nix
    ./observability/tempo.nix
    ./portal.nix
    ./security/bws-backup.nix
    ./security/cert-manager.nix
    ./security/external-secrets
    ./security/generated-secrets.nix
    ./security/kubelet-csr-approver.nix
    ./storage/backup-verify.nix
    ./storage/clickhouse.nix
    ./storage/dragonflydb.nix
    ./storage/postgres.nix
    ./storage/retain.nix
    ./storage/rook-ceph.nix
    ./storage/volsync.nix
  ];
  # Admin-only namespaces: tiles hidden from, and oauth2-proxy upstreams closed
  # to, everyone outside Keycloak `admin` (apps override per tile).
  nixidy.portal.defaults = {
    cicd.groups = ["admin"];
    identity.groups = ["admin"];
    observability.groups = ["admin"];
    printing.groups = ["admin"];
    storage.groups = ["admin"];
  };
  nixidy.applications.namespaces = {
    namespace = "kube-system";
    annotations."argocd.argoproj.io/sync-wave" = "1";
    canivete.bootstrap.enable = true;
    resources.namespaces = {
      ai = {};
      ai-sandbox = {};
      backup-verify = {};
      cicd = {};
      mail = {};
      observability = {};
      security = {};
      storage = {};
    };
  };
}
