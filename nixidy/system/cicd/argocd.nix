{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  devenv = {pkgs, ...}: {packages = [pkgs.argocd];};
  nixidy = {
    charts,
    lib,
    ...
  }: {
    # OAuth2Client CRD — lands in identity namespace via hydra app, co-located here with consumer
    applications.hydra.resources.oAuth2Clients.argocd.spec = {
      secretName = "argocd-hydra-client";
      clientName = "ArgoCD";
      grantTypes = ["authorization_code" "refresh_token"];
      redirectUris = ["https://argocd.${domain}/auth/callback"];
      responseTypes = ["code"];
      scope = "openid profile email";
      tokenEndpointAuthMethod = "client_secret_post";
    };

    gatus.endpoints.argo = { url = "https://argocd.${domain}"; group = "internal"; };
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
            extraArgs = ["--insecure"];
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
      resources.httpRoutes.argo.spec = {
        hostnames = ["argocd.${domain}"];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "argod-argocd-server";
            port = 80;
          };
        };
      };
      # OAuth2 client credentials for Ory Hydra OIDC
      resources.externalSecrets.argocd-oidc.spec = {
        secretStoreRef = {
          name = "kubernetes-identity";
          kind = "ClusterSecretStore";
        };
        target.name = "argocd-secret";
        target.creationPolicy = "Merge";
        data = [
          {
            secretKey = "oidc.argocd.clientID";
            remoteRef.key = "argocd-hydra-client";
            remoteRef.property = "CLIENT_ID";
          }
          {
            secretKey = "oidc.argocd.clientSecret";
            remoteRef.key = "argocd-hydra-client";
            remoteRef.property = "CLIENT_SECRET";
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
