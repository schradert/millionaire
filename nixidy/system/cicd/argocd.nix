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
          dex.enabled = false;
          server = {
            httproute.enabled = true;
            httproute.parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            config."oidc.config" = builtins.toJSON {
              name = "Ory";
              issuer = "https://hydra.${domain}";
              clientID = "$oidc.argocd.clientID";
              clientSecret = "$oidc.argocd.clientSecret";
              requestedScopes = ["openid" "profile" "email"];
            };
          };
        };
      };
      # OAuth2 client credentials for Ory Hydra OIDC
      resources.externalSecrets.argocd-oidc.spec = {
        secretStoreRef = {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        target.name = "argocd-secret";
        target.creationPolicy = "Merge";
        data = [
          {
            secretKey = "oidc.argocd.clientID";
            remoteRef.key = "ory/argocd/client-id";
          }
          {
            secretKey = "oidc.argocd.clientSecret";
            remoteRef.key = "ory/argocd/client-secret";
          }
        ];
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
