{
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    # Approves kubelet serving-cert CSRs (only issued when kubelets run with
    # serverTLSBootstrap / rotate-server-certificates).
    applications.kubelet-csr-approver = {
      namespace = "security";
      helm.releases.kubelet-csr-approver = {
        chart = pinned.charts.kubelet-csr-approver;
        values = {
          image = {
            inherit (pinned.images.kubelet-csr-approver) repository;
            tag = with pinned.images.kubelet-csr-approver; "${tag}@${digest}";
          };
          providerRegex = "^[a-z0-9-]+$";
          providerIpPrefixes = ["192.168.50.0/24" "100.64.0.0/10"];
          bypassDnsResolution = true;
        };
      };
      # The chart gates its ServiceMonitor on .Capabilities, which helm template lacks.
      resources.serviceMonitors.kubelet-csr-approver = {
        metadata.labels.release = "prometheus";
        spec = {
          selector.matchLabels."app.kubernetes.io/name" = "kubelet-csr-approver";
          endpoints = lib.toList {
            port = "metrics";
            interval = "1m";
          };
        };
      };
    };
  };
}
