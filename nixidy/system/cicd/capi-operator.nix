# Cluster API operator — declarative provider lifecycle for the scoped-CAPI
# cloud-burst architecture. The operator replaces imperative `clusterctl init`:
# providers are CRs, pinned and GitOps-managed. Scope is deliberately minimal —
# core + Hetzner infrastructure only. NO bootstrap or control-plane providers:
# workers bypass them via Machine.spec.bootstrap.dataSecretName (CAPRKE2 cannot
# join an externally managed RKE2 control plane and its cloud-init fights
# NixOS), and the home control plane stays Pulumi-managed.
{...}: {
  nixidy = {
    lib,
    pkgs,
    ...
  }: {
    applications.namespaces.resources.namespaces = {
      capi = {};
      capi-system = {};
      caph-system = {};
    };

    # Operator CRD types for nixidy (the chart installs the CRDs themselves).
    canivete.crds.capi-operator = {
      application = "capi-operator";
      prefix = "config/crd/bases";
      src = pkgs.fetchFromGitHub {
        owner = "kubernetes-sigs";
        repo = "cluster-api-operator";
        rev = "v0.27.0";
        hash = "sha256-tmdmi23AEc9BsslQSG6N88RpE9qGuy+acIzw/Ni9v5g=";
      };
    };

    applications.capi-operator = {
      namespace = "capi";
      helm.releases.cluster-api-operator = {
        chart = lib.helm.downloadHelmChart {
          repo = "https://kubernetes-sigs.github.io/cluster-api-operator";
          chart = "cluster-api-operator";
          version = "0.27.0";
          chartHash = "sha256-XYJaGk3fU0rL9MMP8vWLS4OFrUdhHDcEwUumJUgHXPU=";
        };
        values = {
          resources.manager = {
            requests.cpu = "50m";
            requests.memory = "64Mi";
            limits.memory = "128Mi";
          };
        };
      };
      # Providers reconcile after the operator + its CRDs exist; Argo must not
      # dry-run them against CRDs that are not applied yet.
      resources.coreProviders.cluster-api = {
        metadata.namespace = "capi-system";
        metadata.annotations = {
          "argocd.argoproj.io/sync-wave" = "1";
          "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true";
        };
        spec.version = "v1.13.2";
      };
      resources.infrastructureProviders.hetzner = {
        metadata.namespace = "caph-system";
        metadata.annotations = {
          "argocd.argoproj.io/sync-wave" = "1";
          "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true";
        };
        spec.version = "v1.1.6";
      };
    };
  };
}
