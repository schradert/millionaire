{
  nixidy = {
    pinned,
    pkgs,
    ...
  }: let
    repo = pinned.dragonfly-operator;
  in {
    applications.dragonflydb-crds.namespace = "kube-system";
    canivete.crds.dragonflydb = {
      application = "dragonflydb-crds";
      install = true;
      src = repo;
      prefix = "manifests";
      match = "^crd\.yaml$";
    };
    applications.dragonflydb = {
      namespace = "storage";
      helm.releases.dragonflydb = {
        chart = pkgs.runCommand "dragonfly-operator" {} "cp -aL ${repo}/charts/dragonfly-operator $out";
        values = {
          # The CRD is owned by dragonflydb-crds above; the chart's copy (with a
          # helm keep annotation) made the two apps fight over it.
          crds.install = false;
          serviceMonitor.enabled = true;
          # FIXME activate with grafana
          # grafanaDashboard.enabled = true;
          # grafanaDashboard.grafanaOperator.enabled = true;
        };
      };
    };
  };
}
