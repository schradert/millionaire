{...}: {
  nixidy = {pinned, ...}: let
    chart = pinned.charts.gpu-operator;
  in {
    applications.nvidia-gpu-operator-crds = {
      namespace = "kube-system";
    };
    canivete.crds.nvidia-gpu-operator = {
      application = "nvidia-gpu-operator-crds";
      install = true;
      prefix = "crds";
      src = chart;
    };
    applications.nvidia-gpu-operator = {
      namespace = "ai";
      helm.releases.nvidia-gpu-operator = {
        inherit chart;
        values = {
          # NixOS handles NVIDIA drivers and container toolkit at the OS level
          driver.enabled = false;
          toolkit.enabled = false;
          # Device plugin advertises GPU resources to k8s scheduler
          devicePlugin.enabled = true;
          # DCGM exporter for Prometheus GPU metrics
          dcgmExporter = {
            enabled = true;
            serviceMonitor.enabled = true;
          };
          # The cluster's only Node Feature Discovery (all sources: pci, usb, system, ...).
          # A standalone NFD would collide with these CRDs and labels.
          nfd.enabled = true;
          # Disable GDS and GDRCopy (not needed for inference)
          gds.enabled = false;
          gdrcopy.enabled = false;
        };
      };
    };
  };
}
