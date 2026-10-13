# Grafana dashboards, picked up by the grafana sidecar (grafana_dashboard label, all namespaces).
# One ConfigMap per file in ./dashboards. Prometheus and Loki are referenced by the datasource uids
# set in grafana.nix. Downloaded ones come from grafana.com (node-exporter-full 1860, ceph-cluster 2842,
# ceph-pools 5342, argocd-operational 19993, cert-manager 20842, alertmanager 9578), the exportarr
# repo and the external-secrets repo, with the datasource inputs pinned to those uids.
{...}: {
  nixidy = {lib, ...}: {
    applications.grafana.resources.configMaps = lib.mapAttrs' (file: _:
      lib.nameValuePair "dashboard-${lib.removeSuffix ".json" file}" {
        metadata.labels.grafana_dashboard = "1";
        data.${file} = builtins.readFile (./dashboards + "/${file}");
      }) (builtins.readDir ./dashboards);
  };
}
