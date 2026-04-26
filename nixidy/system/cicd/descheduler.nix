{...}: {
  nixidy = {lib, ...}: {
    applications.descheduler = {
      namespace = "cicd";
      helm.releases.descheduler = {
        chart = lib.helm.downloadHelmChart {
          repo = "https://kubernetes-sigs.github.io/descheduler";
          chart = "descheduler";
          version = "0.35.1";
          chartHash = "sha256-eugw/YckC6dI6kIYbNwK/5CYQvAwaFFbkeD9Si4fdn4=";
        };
        values = {
          replicas = 1;
          kind = "Deployment";
          image.tag = "v0.35.1";
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
