{config, ...}: {
  devenv = {pkgs, ...}: {packages = [pkgs.argocd];};
  nixidy = {charts, ...}: {
    applications.argo = {
      canivete.bootstrap.enable = true;
      namespace = "cicd";
      helm.releases.argod = {
        chart = charts.argoproj.argo-cd;
        values.global.domain = "argocd.${config.canivete.meta.domain}";
      };
    };
  };
}
