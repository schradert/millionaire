{
  nixidy = {lib, ...}: {
    applications.reloader = {
      namespace = "cicd";
      helm.releases.reloader.chart = lib.helm.downloadHelmChart {
        chart = "reloader";
        version = "2.2.9";
        repo = "oci://ghcr.io/stakater/charts";
        chartHash = "sha256-cdGekNPr8381ZWzzuj1vYZD4DeC11vT3Csb94shr4PM=";
      };
    };
  };
}
