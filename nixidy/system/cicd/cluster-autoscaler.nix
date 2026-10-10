# Cluster Autoscaler in clusterapi mode — the pod-driven brain of cloud-burst.
# Watches for unschedulable pods, simulates against ALL nodes (home included),
# and only when nothing fits scales the annotated MachineDeployment
# (capi-cluster.nix) between its min/max. Same binary EKS/GKE users run; the
# clusterapi provider scales MachineDeployments instead of calling a cloud API,
# which keeps the autoscaler provider-agnostic as more infra providers land.
{...}: {
  nixidy = {pinned, ...}: {
    applications.cluster-autoscaler = {
      namespace = "capi";
      helm.releases.cluster-autoscaler = {
        chart = pinned.charts.cluster-autoscaler;
        values = {
          cloudProvider = "clusterapi";
          # Management cluster == workload cluster: in-cluster client for both.
          clusterAPIMode = "incluster-incluster";
          # Scope to MachineDeployments labeled with our cluster name.
          autoDiscovery.clusterName = "millionaire";
          extraArgs = {
            # Burst capacity should linger briefly, not forever.
            scale-down-unneeded-time = "10m";
            scale-down-delay-after-add = "10m";
            # Workers run only burst pods; evicting kube-system DaemonSet
            # pods is expected during drain.
            skip-nodes-with-system-pods = "false";
          };
          podAnnotations."reloader.stakater.com/auto" = "true";
          resources = {
            requests.cpu = "50m";
            requests.memory = "128Mi";
            limits.memory = "256Mi";
          };
        };
      };
    };
  };
}
