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

    gatus.endpoints.argo = {
      url = "https://argocd.${domain}";
      group = "internal";
    };
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
          # ServerSideApply can't strip controller-/apiserver-defaulted fields,
          # so ExternalSecret + HTTPRoute render minimal in git but gain defaults
          # live -> perpetual OutOfSync across nearly every app (self-heal then
          # backs off). Ignore the defaulted fields cluster-wide via argocd-cm.
          # NOTE: configs.cm, NOT server.config — server.config is a no-op in this
          # chart version (the server.config."oidc.config" above likewise never
          # reaches the rendered argocd-cm; flagged for separate follow-up). One
          # place covers every current + future app; resources are functional, so
          # this is cosmetic diff-suppression, not a behaviour change.
          configs.cm = {
            "resource.customizations.ignoreDifferences.external-secrets.io_ExternalSecret" = builtins.toJSON {
              jqPathExpressions = [
                ".spec.refreshInterval"
                ".spec.target.creationPolicy"
                ".spec.target.deletionPolicy"
                ".spec.target.template.engineVersion"
                ".spec.target.template.mergePolicy"
                ".spec.data[]?.remoteRef.conversionStrategy"
                ".spec.data[]?.remoteRef.decodingStrategy"
                ".spec.data[]?.remoteRef.metadataPolicy"
              ];
            };
            # gateway-api apiserver defaults parentRefs.group/kind,
            # backendRefs.group/kind/weight, and injects a PathPrefix "/" match
            # when a route omits matches. Trade-off: a real change to .matches on
            # a route that omits them won't diff — acceptable (routes that set
            # matches explicitly never drifted).
            "resource.customizations.ignoreDifferences.gateway.networking.k8s.io_HTTPRoute" = builtins.toJSON {
              jqPathExpressions = [
                ".spec.parentRefs[]?.group"
                ".spec.parentRefs[]?.kind"
                ".spec.rules[]?.backendRefs[]?.group"
                ".spec.rules[]?.backendRefs[]?.kind"
                ".spec.rules[]?.backendRefs[]?.weight"
                ".spec.rules[]?.matches"
              ];
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
