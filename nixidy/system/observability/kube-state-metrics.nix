{...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: {
    applications.kube-state-metrics = {
      namespace = "observability";
      helm.releases.kube-state-metrics = {
        chart = pinned.charts.kube-state-metrics;
        values = {
          fullnameOverride = "kube-state-metrics";
          image = with pinned.images.kube-state-metrics; {
            inherit tag;
            sha = digest;
          };
          # Application.status.operationState as metrics (ArgoCDOperationStuck).
          rbac.extraRules = lib.toList {
            apiGroups = ["argoproj.io"];
            resources = ["applications"];
            verbs = ["list" "watch"];
          };
          annotations."reloader.stakater.com/auto" = "true";
          customResourceState = {
            enabled = true;
            config = {
              kind = "CustomResourceStateMetrics";
              spec.resources = lib.toList {
                groupVersionKind = {
                  group = "argoproj.io";
                  version = "v1alpha1";
                  kind = "Application";
                };
                metricNamePrefix = "argocd_application";
                labelsFromPath = {
                  name = ["metadata" "name"];
                  namespace = ["metadata" "namespace"];
                };
                metrics = [
                  {
                    name = "operation_phase";
                    help = "status.operationState.phase of the Application";
                    each = {
                      type = "StateSet";
                      stateSet = {
                        labelName = "phase";
                        path = ["status" "operationState" "phase"];
                        list = ["Running" "Terminating" "Succeeded" "Failed" "Error"];
                      };
                    };
                  }
                  {
                    name = "operation_started_timestamp_seconds";
                    help = "status.operationState.startedAt of the Application";
                    each = {
                      type = "Gauge";
                      gauge.path = ["status" "operationState" "startedAt"];
                    };
                  }
                ];
              };
            };
          };
          prometheus.monitor = {
            enabled = true;
            honorLabels = true;
          };
        };
      };
    };
  };
}
