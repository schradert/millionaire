{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    chart = charts.prometheus-community.kube-prometheus-stack;
  in {
    canivete.crds.prometheus = {
      prefix = "charts/crds/crds";
      install = true;
      src = chart;
    };
    applications.prometheus = {
      namespace = "observability";
      canivete.bootstrap.enable = true;
      annotations."argocd.argoproj.io/sync-wave" = "4";
      # volsync.pvcs.prometheus = {
      #   title = "prometheus-prometheus-kube-prometheus-prometheus-db-prometheus-prometheus-kube-prometheus-prometheus-0";
      #   # TODO what happens with multiple deployments???
      #   # TODO resurrect this injection when StorageClass changes
      #   # path = ["prometheuses" "prometheus-kube-prometheus-prometheus" "spec" "storage" "volumeClaimTemplate"];
      # };
      helm.releases.prometheus = {
        chart = charts.prometheus-community.kube-prometheus-stack;
        values = {
          crds.enabled = false;
          kubelet.enabled = true;
          kubeApiServer.enabled = true;
          prometheus = {
            prometheusSpec.storageSpec.volumeClaimTemplate.spec = {
              accessModes = ["ReadWriteOnce"];
              resources.requests.storage = "10Gi";
            };
            route.main = {
              enabled = true;
              hostnames = ["prometheus.${config.canivete.meta.domain}"];
              parentRefs = lib.toList {
                name = "internal";
                namespace = "kube-system";
                sectionName = "https";
              };
            };
          };
          prometheusOperator.admissionWebhooks.deployment.enabled = true;

          # Deployed separately
          alertmanager.enabled = false;
          kubeControllerManager.enabled = false;
          kubeEtcd.enabled = false;
          kubeProxy.enabled = false;
          kubeScheduler.enabled = false;
          kubeStateMetrics.enabled = false;
          nodeExporter.enabled = false;
          grafana.enabled = false;
          grafana.forceDeployDashboards = true;
        };
      };
    };
  };
}
