{...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.descheduler = {
      namespace = "cicd";
      helm.releases.descheduler = {
        chart = pinned.charts.descheduler;
        values = {
          replicas = 1;
          # 3m at p95 over 7d; the 500m limit stays.
          resources.requests.cpu = "50m";
          kind = "Deployment";
          image.tag = with pinned.images.descheduler; "${tag}@${digest}";
          deschedulerPolicyAPIVersion = "descheduler/v1alpha2";
          deschedulerPolicy.profiles = lib.toList {
            name = "Default";
            pluginConfig = [
              {name = "RemovePodsViolatingInterPodAntiAffinity";}
              {name = "RemovePodsViolatingNodeTaints";}
              {
                name = "RemovePodsViolatingNodeAffinity";
                args.nodeAffinityType = ["requiredDuringSchedulingIgnoredDuringExecution"];
              }
              {
                name = "RemovePodsViolatingTopologySpreadConstraint";
                args.constraints = ["DoNotSchedule" "ScheduleAnyway"];
              }
              {
                name = "DefaultEvictor";
                args = {
                  evictFailedBarePods = true;
                  evictLocalStoragePods = true;
                  evictSystemCriticalPods = true;
                  nodeFit = true;
                };
              }
            ];
            plugins.balance.enabled = ["RemovePodsViolatingTopologySpreadConstraint"];
            plugins.deschedule.enabled = [
              "RemovePodsViolatingInterPodAntiAffinity"
              "RemovePodsViolatingNodeAffinity"
              "RemovePodsViolatingNodeTaints"
            ];
          };
          service.enabled = true;
          serviceMonitor.enabled = true;
          leaderElection.enabled = true;
        };
      };
    };
  };
}
