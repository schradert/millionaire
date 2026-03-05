{
  imports = [./bitwarden.nix];
  nixidy = {
    charts,
    config,
    lib,
    pkgs,
    ...
  }: let
    namespace = "security";
    name = "external-secrets-kubernetes";
  in {
    canivete.crds.external-secrets = {
      application = "crds";
      install = true;
      prefix = "config/crds/bases";
      match = ".*_.*\\.yaml$";  # CRD files contain underscores, kustomization.yaml doesn't
      src = pkgs.fetchFromGitHub {
        owner = "external-secrets";
        repo = "external-secrets";
        rev = "v2.0.1";
        hash = "sha256-VKsruSQIkSkmU7sAznO5Ex/DF3TsykR+Gd5epd42tlw=";
      };
    };
    applications.external-secrets = {
      namespace = "security";
      helm.releases.external-secrets = {
        chart = charts.external-secrets.external-secrets;
        values = {
          installCRDs = false;
          serviceMonitor.enabled = true;
        };
      };
      resources = {
        clusterSecretStores = lib.flip lib.mapAttrs' config.applications.namespaces.resources.namespaces (ns: _:
          lib.nameValuePair "kubernetes-${ns}" {
            spec.provider.kubernetes = {
              auth.serviceAccount = {inherit name namespace;};
              remoteNamespace = "default";
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
