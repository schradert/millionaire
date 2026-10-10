{...}: {
  nixidy = {pinned, ...}: let
    chart = pinned.charts.gpu-operator;
    v = i: "${i.tag}@${i.digest}";
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
          # The operator builds <repository>/<image>:<version>, so version
          # carries tag@digest.
          operator.version = v pinned.images.gpu-operator;
          operator.initContainer.version = v pinned.images.gpu-cuda;
          validator.version = v pinned.images.gpu-validator;
          nodeStatusExporter.version = v pinned.images.gpu-validator;
          devicePlugin.version = v pinned.images.gpu-device-plugin;
          gfd.version = v pinned.images.gpu-device-plugin;
          dcgmExporter.version = v pinned.images.gpu-dcgm-exporter;
          dcgm.version = v pinned.images.gpu-dcgm;
          migManager.version = v pinned.images.gpu-mig-manager;
          sandboxDevicePlugin.version = v pinned.images.gpu-sandbox-device-plugin;
          vfioManager.version = v pinned.images.gpu-cuda;
          vgpuDeviceManager.version = v pinned.images.gpu-vgpu-device-manager;
          toolkit.version = v pinned.images.gpu-toolkit;
          ccManager.version = v pinned.images.gpu-cc-manager;
          kataManager.version = v pinned.images.gpu-kata-manager;
          driver.manager.version = v pinned.images.gpu-driver-manager;
          vfioManager.driverManager.version = v pinned.images.gpu-driver-manager;
          vgpuManager.driverManager.version = v pinned.images.gpu-driver-manager;
          node-feature-discovery.image.tag = v pinned.images.node-feature-discovery;
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
