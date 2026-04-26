{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    # Keycloak OIDC client — Hostzero operator syncs secret to K8s
    applications.keycloak.resources.keycloakClients.argocd.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "argocd";
        create = true;
      };
      definition = {
        clientId = "argocd";
        name = "ArgoCD";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://argocd.${domain}/auth/callback"];
        webOrigins = ["https://argocd.${domain}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    gatus.endpoints.argo = {url = "https://argocd.${domain}"; group = "internal";};
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
              name = "Keycloak";
              issuer = "https://keycloak.${domain}/realms/default";
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
      # Keycloak OIDC client credentials (Hostzero operator syncs to K8s Secret)
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
            remoteRef.key = "argocd"; # Keycloak client secret name
            remoteRef.property = "client-id";
          }
          {
            secretKey = "oidc.argocd.clientSecret";
            remoteRef.key = "argocd";
            remoteRef.property = "client-secret";
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
