# Cluster Autoscaler in clusterapi mode — the pod-driven brain of cloud-burst.
# Watches for unschedulable pods, simulates against ALL nodes (home included),
# and only when nothing fits scales the annotated MachineDeployment
# (capi-cluster.nix) between its min/max. Same binary EKS/GKE users run; the
# clusterapi provider scales MachineDeployments instead of calling a cloud API,
# which keeps the autoscaler provider-agnostic as more infra providers land.
{...}: {
  nixidy = {lib, ...}: {
    applications.cluster-autoscaler = {
      namespace = "capi";
      helm.releases.cluster-autoscaler = {
        chart = lib.helm.downloadHelmChart {
          repo = "https://kubernetes.github.io/autoscaler";
          chart = "cluster-autoscaler";
          version = "9.57.0";
          chartHash = "sha256-TfMNgTwq0g+faac8ReRD4bMls45kv1IwuLt08Ov0fjE=";
        };
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
