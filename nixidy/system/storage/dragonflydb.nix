{
  nixidy = {pkgs, ...}: let
    repo = pkgs.fetchFromGitHub {
      owner = "dragonflydb";
      repo = "dragonfly-operator";
      rev = "v1.4.0";
      hash = "sha256-QBylTbY+8HcD0Z2VyqtwUYm+MeXCP7IwVtJpCCMswXs=";
    };
  in {
    canivete.crds.dragonflydb = {
      src = repo;
      prefix = "manifests";
      match = "^crd\.yaml$";
    };
    applications.dragonflydb = {
      namespace = "storage";
      helm.releases.dragonflydb = {
        chart = pkgs.runCommand "dragonfly-operator" {} "cp -aL ${repo}/charts/dragonfly-operator $out";
        values = {
          serviceMonitor.enabled = true;
          # FIXME activate with grafana
          # grafanaDashboard.enabled = true;
          # grafanaDashboard.grafanaOperator.enabled = true;
        };
      };
    };
  };
}
