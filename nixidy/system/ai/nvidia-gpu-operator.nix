{...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
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
          # 3m at p95 over 7d, against the chart's 200m; its limits stay.
          operator.resources.requests.cpu = "50m";
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
          # With the host driver the validator would modprobe via chroot /host (/sbin/modprobe does
          # not exist on NixOS) to create /dev/char links; udev already makes them.
          validator.driver.env = lib.toList {
            name = "DISABLE_DEV_CHAR_SYMLINK_CREATION";
            value = "true";
          };
          # Device plugin advertises GPU resources to k8s scheduler. Index IDs: the CDI spec NixOS
          # generates (static/desktop-node.nix) names devices by index, not UUID. The env list
          # replaces the chart's, so its other defaults are repeated.
          devicePlugin.enabled = true;
          devicePlugin.env = [
            {
              name = "PASS_DEVICE_SPECS";
              value = "true";
            }
            {
              name = "FAIL_ON_INIT_ERROR";
              value = "true";
            }
            {
              name = "DEVICE_LIST_STRATEGY";
              value = "envvar";
            }
            {
              name = "DEVICE_ID_STRATEGY";
              value = "index";
            }
            {
              name = "NVIDIA_VISIBLE_DEVICES";
              value = "all";
            }
            {
              name = "NVIDIA_DRIVER_CAPABILITIES";
              value = "all";
            }
          ];
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
      resources.podMonitors.node-feature-discovery.spec = {
        selector.matchLabels."app.kubernetes.io/name" = "node-feature-discovery";
        podMetricsEndpoints = lib.toList {
          port = "metrics";
          interval = "1m";
        };
      };
    };
  };
}
