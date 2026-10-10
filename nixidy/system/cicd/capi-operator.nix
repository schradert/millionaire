# Cluster API operator — declarative provider lifecycle for the scoped-CAPI
# cloud-burst architecture. The operator replaces imperative `clusterctl init`:
# providers are CRs, pinned and GitOps-managed. Scope is deliberately minimal —
# core + Hetzner infrastructure only. NO bootstrap or control-plane providers:
# workers bypass them via Machine.spec.bootstrap.dataSecretName (CAPRKE2 cannot
# join an externally managed RKE2 control plane and its cloud-init fights
# NixOS), and the home control plane stays Pulumi-managed.
{...}: {
  nixidy = {
    pinned,
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
      src = pinned.cluster-api-operator;
    };

    applications.capi-operator = {
      namespace = "capi";
      helm.releases.cluster-api-operator = {
        chart = pinned.charts.cluster-api-operator;
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
        spec.version = "v${pinned.cluster-api.pin.version}";
      };
      resources.infrastructureProviders.hetzner = {
        metadata.namespace = "caph-system";
        metadata.annotations = {
          "argocd.argoproj.io/sync-wave" = "1";
          "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true";
        };
        spec.version = "v${pinned.cluster-api-provider-hetzner.pin.version}";
      };
    };
  };
}
