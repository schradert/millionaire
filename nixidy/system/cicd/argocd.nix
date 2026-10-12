{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {
    pinned,
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
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };

    # `argocd login --sso` (modules/kubernetes.nix): PKCE on a localhost callback.
    applications.keycloak.resources.keycloakClients.argocd-cli.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "argocd-cli";
        name = "ArgoCD CLI";
        enabled = true;
        protocol = "openid-connect";
        publicClient = true;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["http://localhost:8085/auth/callback"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
        attributes."pkce.code.challenge.method" = "S256";
      };
    };

    portal.apps.argo = {
      title = "ArgoCD";
      icon = "argo-cd";
      description = "GitOps continuous delivery";
    };
    gatus.endpoints.argo = {
      url = "https://argocd.${domain}";
      group = "internal";
    };
    applications.argo = {
      canivete.bootstrap.enable = true;
      namespace = "cicd";
      helm.releases.argod = {
        chart = pinned.charts.argo-cd;
        values = {
          global.image = with pinned.images.argocd; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          redis.image = with pinned.images.argocd-redis; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          global.domain = "argocd.${domain}";
          # Chart 10 defaults this to true; policies here are CiliumNetworkPolicies.
          global.networkPolicy.create = false;
          # TODO activate HA mode with autoscaling (after multi-node)
          # redis-ha.enabled = true;
          # controller.replicas = 1;
          # server.autoscaling.enabled = true;
          # server.autoscaling.minReplicas = 2;
          # repoServer.autoscaling.enabled = true;
          # repoServer.autoscaling.minReplicas = 2;
          # applicationSet.replicas = 2;
          dex.enabled = false;
          # argocd_app_info / argocd_app_sync_total for the alerts below.
          # (The chart's own ServiceMonitor is gated on cluster capabilities, which
          # helm template lacks; see resources.serviceMonitors.argocd-controller.)
          controller.metrics.enabled = true;
          server.extraArgs = ["--insecure"];
          # Keycloak SSO; the local admin stays enabled as break-glass
          # (argocd-initial-admin-secret, pushed to Bitwarden below).
          configs.cm."oidc.config" = builtins.toJSON {
            name = "Keycloak";
            issuer = "https://keycloak.${domain}/realms/default";
            clientID = "$oidc.argocd.clientID";
            clientSecret = "$oidc.argocd.clientSecret";
            cliClientID = "argocd-cli";
            requestedScopes = ["openid" "profile" "email" "groups"];
          };
          configs.rbac."policy.csv" = "g, admin, role:admin";
          # ServerSideApply can't strip controller-/apiserver-defaulted fields,
          # so ExternalSecret + HTTPRoute render minimal in git but gain defaults
          # live -> perpetual OutOfSync across nearly every app (self-heal then
          # backs off). Ignore the defaulted fields cluster-wide via argocd-cm.
          # NOTE: configs.cm, NOT server.config — server.config is a no-op in this
          # chart version. One
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
                ".spec.dataFrom[]?.extract.conversionStrategy"
                ".spec.dataFrom[]?.extract.decodingStrategy"
                ".spec.dataFrom[]?.extract.metadataPolicy"
              ];
            };
            # Defaults inside list items (arrays are replaced wholesale when the
            # diff is predicted, so list-item defaults show up as drift).
            "resource.customizations.ignoreDifferences.external-secrets.io_PushSecret" = builtins.toJSON {
              jqPathExpressions = [
                ".spec.data[]?.conversionStrategy"
              ];
            };
            "resource.customizations.ignoreDifferences.gateway.networking.k8s.io_Gateway" = builtins.toJSON {
              jqPathExpressions = [
                ".spec.listeners[]?.tls.mode"
                ".spec.listeners[]?.tls.certificateRefs[]?.group"
              ];
            };
            "resource.customizations.ignoreDifferences.postgresql.cnpg.io_Cluster" = builtins.toJSON {
              jqPathExpressions = [
                ".spec.managed.roles[]?.connectionLimit"
                ".spec.managed.roles[]?.inherit"
              ];
            };
            # The apiserver stamps apiVersion/kind/status onto each
            # volumeClaimTemplate; charts that omit them (alertmanager, the
            # app-template mongodb) otherwise stay OutOfSync.
            "resource.customizations.ignoreDifferences.apps_StatefulSet" = builtins.toJSON {
              jqPathExpressions = [
                ".spec.volumeClaimTemplates[]?.apiVersion"
                ".spec.volumeClaimTemplates[]?.kind"
                ".spec.volumeClaimTemplates[]?.status"
              ];
            };
            # gateway-api apiserver defaults parentRefs.group/kind,
            # backendRefs.group/kind/weight, a PathPrefix "/" match when a rule
            # omits matches, and that same path inside header-only matches. Only
            # those defaults are ignored: a blanket `.matches` ignore hid real
            # match edits (forgejo-api's token-endpoint match never applied).
            "resource.customizations.ignoreDifferences.gateway.networking.k8s.io_HTTPRoute" = builtins.toJSON {
              jqPathExpressions = [
                ".spec.parentRefs[]?.group"
                ".spec.parentRefs[]?.kind"
                ".spec.rules[]?.backendRefs[]?.group"
                ".spec.rules[]?.backendRefs[]?.kind"
                ".spec.rules[]?.backendRefs[]?.weight"
                ''.spec.rules[]? | select(.matches == [{"path":{"type":"PathPrefix","value":"/"}}]) | .matches''
                ''.spec.rules[]?.matches[]? | select(.path == {"type":"PathPrefix","value":"/"}) | .path''
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
      resources.serviceMonitors.argocd-controller.spec = {
        selector.matchLabels = {
          "app.kubernetes.io/instance" = "argod";
          "app.kubernetes.io/name" = "argocd-metrics";
          "app.kubernetes.io/component" = "application-controller";
        };
        endpoints = lib.toList {
          port = "http-metrics";
          interval = "30s";
        };
      };
      # argocd_application_* come from kube-state-metrics custom resource state
      # (observability/kube-state-metrics.nix): the controller's own metrics do not
      # expose status.operationState, which is what a stale sync leaves behind.
      resources.prometheusRules.argocd = {
        metadata.labels.release = "prometheus";
        spec.groups = lib.toList {
          name = "argocd";
          rules = [
            {
              alert = "ArgoCDOperationStuck";
              expr = ''
                (time() - argocd_application_operation_started_timestamp_seconds > 900)
                and on (namespace, name) argocd_application_operation_phase{phase=~"Running|Terminating"} == 1
              '';
              "for" = "2m";
              labels.severity = "warning";
              annotations = {
                summary = "ArgoCD app {{ $labels.name }} has had a sync operation Running for over 15m";
                description = ''
                  A stale status.operationState (typically an old one-resource auto-heal sync) blocks every later
                  sync and its PostSync hooks. Check: kubectl -n cicd get application {{ $labels.name }} -o jsonpath='{.status.operationState}'.
                  If it is not a real sync in progress, clear it: kubectl -n cicd patch application {{ $labels.name }}
                  --type=json -p='[{"op":"remove","path":"/status/operationState"}]',
                  then hard-refresh (annotate argocd.argoproj.io/refresh=hard --overwrite).
                '';
              };
            }
            {
              alert = "ArgoCDSyncFailingRepeatedly";
              expr = ''sum by (namespace, name) (increase(argocd_app_sync_total{phase=~"Error|Failed"}[1h])) >= 3'';
              "for" = "5m";
              labels.severity = "warning";
              annotations = {
                summary = "ArgoCD app {{ $labels.name }} failed to sync 3+ times in the last hour";
                description = ''
                  Look at the last operation: kubectl -n cicd get application {{ $labels.name }} -o jsonpath='{.status.operationState.message}'.
                  A stale or failed status.operationState can be cleared as for ArgoCDOperationStuck.
                '';
              };
            }
            {
              alert = "ArgoCDControllerNotScraped";
              expr = ''absent(argocd_app_info)'';
              "for" = "15m";
              labels.severity = "warning";
              annotations.summary = "No argocd_app_info series: the argocd-application-controller is not being scraped, so the stuck-sync alerts are blind";
            }
          ];
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

      # Break-glass local admin password (argocd generates it on install).
      resources.pushSecrets.argocd-admin.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "argocd-initial-admin-secret";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "argocd/admin-password";
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
