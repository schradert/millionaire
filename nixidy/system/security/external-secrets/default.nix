{
  imports = [./bitwarden.nix];
  nixidy = {
    config,
    lib,
    pinned,
    ...
  }: let
    namespace = "security";
    name = "external-secrets-kubernetes";
  in {
    applications.external-secrets-crds.namespace = "kube-system";
    canivete.crds.external-secrets = {
      application = "external-secrets-crds";
      install = true;
      prefix = "config/crds/bases";
      match = ".*_.*\\.yaml$"; # CRD files contain underscores, kustomization.yaml doesn't
      src = pinned.external-secrets;
    };
    applications.external-secrets = {
      namespace = "security";
      helm.releases.external-secrets = {
        chart = pinned.charts.external-secrets;
        values = {
          image.tag = with pinned.images.external-secrets; "${tag}@${digest}";
          webhook.image.tag = with pinned.images.external-secrets; "${tag}@${digest}";
          certController.image.tag = with pinned.images.external-secrets; "${tag}@${digest}";
          bitwarden-sdk-server.image.tag = with pinned.images.bitwarden-sdk-server; "${tag}@${digest}";
          installCRDs = false;
          serviceMonitor.enabled = true;
        };
      };
      resources = {
        clusterSecretStores = lib.flip lib.mapAttrs' config.applications.namespaces.resources.namespaces (ns: _:
          lib.nameValuePair "kubernetes-${ns}" {
            spec.provider.kubernetes = {
              auth.serviceAccount = {inherit name namespace;};
              remoteNamespace = ns;
              server.caProvider = {
                type = "ConfigMap";
                name = "kube-root-ca.crt";
                inherit namespace;
                key = "ca.crt";
              };
            };
          });
        serviceAccounts.${name} = {};
        clusterRoles.${name}.rules = [
          {
            apiGroups = [""];
            resources = ["secrets"];
            verbs = ["get" "list" "watch"];
          }
          {
            apiGroups = ["authorization.k8s.io"];
            resources = ["selfsubjectrulesreviews"];
            verbs = ["create"];
          }
        ];
        clusterRoleBindings.${name} = {
          roleRef = {
            inherit name;
            kind = "ClusterRole";
            apiGroup = "rbac.authorization.k8s.io";
          };
          subjects = lib.toList {
            inherit name namespace;
            kind = "ServiceAccount";
          };
        };
      };
    };
  };
}
