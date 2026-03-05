{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  devenv = {pkgs, ...}: {packages = [pkgs.argocd];};
  nixidy = {
    charts,
    lib,
    ...
  }: {
    applications.argo = {
      canivete.bootstrap.enable = true;
      namespace = "cicd";
      annotations."argocd.argoproj.io/sync-wave" = "6";
      helm.releases.argod = {
        chart = charts.argoproj.argo-cd;
        values = {
          global.domain = "argocd.${domain}";
          # TODO activate HA mode with autoscaling (after multi-node)
          # redis-ha.enabled = true;
          # controller.replicas = 1;
          # server.autoscaling.enabled = true;
          # server.autoscaling.minReplicas = 2;
          # repoServer.autoscaling.enabled = true;
          # repoServer.autoscaling.minReplicas = 2;
          # applicationSet.replicas = 2;
          server.httproute.enabled = true;
          server.httproute.parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
        };
      };
      resources.secrets.argocd-in-cluster = {
        metadata.labels."argocd.argoproj.io/secret-type" = "cluster";
        stringData = {
          name = "in-cluster";
          server = "https://kubernetes.default.svc";
          config = builtins.toJSON {
            tlsClientConfig = {
              insecure = false;
            };
          };
        };
      };
    };
  };
}
