{
  nixidy = {lib, ...}: {
    applications.reloader = {
      namespace = "cicd";
      helm.releases.reloader = {
        chart = lib.helm.downloadHelmChart {
          chart = "reloader";
          version = "2.2.9";
          repo = "oci://ghcr.io/stakater/charts";
          chartHash = "sha256-cdGekNPr8381ZWzzuj1vYZD4DeC11vT3Csb94shr4PM=";
        };
        # Restart workloads when a referenced Secret/ConfigMap is created later
        # (e.g. ExternalSecrets whose Bitwarden keys are added after deploy).
        # syncAfterRestart stays false (chart default) so Reloader's own startup
        # replay of existing resources does not restart anything.
        values.reloader = {
          reloadOnCreate = true;
          syncAfterRestart = false;
        };
      };
    };
  };
}
