{
  config,
  lib,
  ...
}: let
  inherit (config.canivete.meta) domain;
  subdomain = "rook.${domain}";
in {
  nixos = {config, ...}: {
    boot.kernelModules = lib.mkIf config.canivete.kubernetes.enable ["nbd" "rbd"];
  };
  nixidy = {charts, lib, ...}: {
    applications.rook-ceph = {
      namespace = "storage";
      helm.releases.rook-ceph-operator = {
        chart = charts.rook-release.rook-ceph;
        values = lib.mkMerge [
          {
            csi.cephFSKernelMountOptions = "ms_mode=prefer-crc";
            csi.enableCephfsDriver = false;
            csi.enableCephfsSnapshotter = false;
            csi.serviceMonitor.enabled = true;
            monitoring.enabled = true;
            enableDiscoveryDaemon = true;
          }
          {
            # Mount Nix store
            # TODO is this still needed?
            csi = {
              csiCephFSPluginVolume = [
                {
                  name = "lib-modules";
                  hostPath.path = "/run/current-system/kernel-modules/lib/modules/";
                }
                {
                  name = "host-nix";
                  hostPath.path = "/nix";
                }
              ];
              csiCephFSPluginVolumeMount = lib.toList {
                name = "host-nix";
                mountPath = "/nix";
                readOnly = true;
              };
              csiRBDPluginVolume = [
                {
                  name = "lib-modules";
                  hostPath.path = "/run/current-system/kernel-modules/lib/modules/";
                }
                {
                  name = "host-nix";
                  hostPath.path = "/nix";
                }
              ];
              csiRBDPluginVolumeMount = lib.toList {
                name = "host-nix";
                mountPath = "/nix";
                readOnly = true;
              };
            };
          }
        ];
      };
      helm.releases.rook-ceph-cluster = {
        chart = charts.rook-release.rook-ceph-cluster;
        values = {
          operatorNamespace = "storage";
          cephClusterSpec = {
            cephConfig.global = {
              bdev_enable_discard = "true";
              bdev_async_discard_threads = "1";
              osd_class_update_on_start = "false";
              device_failure_prediction_mode = "local";
            };
            cleanupPolicy.wipeDevicesFromOtherClusters = true;
            csi.readAffinity.enabled = true;
            dashboard.urlPrefix = "/";
            dashboard.ssl = false;
            dashboard.prometheusEndpoint = "http" + "://prometheus-operated.monitoring.svc.cluster.local:9090";
            mgr.modules = let
              enable = name: {
                inherit name;
                enabled = true;
              };
            in [
              (enable "diskprediction_local")
              (enable "insights")
              (enable "pg_autoscaler")
              (enable "rook")
            ];
            network.provider = "host";
            network.connections.requireMsgr2 = true;
            storage.useAllNodes = false;
            storage.useAllDevices = false;
            storage.nodes = lib.mkDefault [];
          };
          cephFileSystems = [];
          cephBlockPoolsVolumeSnapshotClass.enabled = true;
          monitoring.enabled = true;
          monitoring.createPrometheusRules = true;
        };
      };
      resources = {
        storageClasses.ceph-bucket.parameters.region = lib.mkForce "us-west-1";
        storageClasses.ceph-block = {
          # TODO should I prevent this from being the default storageclass?
          mountOptions = ["discard"];
          parameters.compression_mode = "aggressive";
          parameters.compression_algorithm = "zstd";
          parameters.imageFeatures = lib.mkForce (builtins.concatStringsSep "," [
            "layering"
            "fast-diff"
            "object-map"
            "deep-flatten"
            "exclusive-lock"
          ]);
        };
        # This secret name is expected by rook-ceph
        externalSecrets.rook-ceph-dashboard-password.spec.data = lib.toList {
          secretKey = "password";
          remoteRef.key = "ceph/dashboard/password";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
        httpRoutes.rook-ceph-dashboard.spec = {
          hostnames = [subdomain];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "rook-ceph-mgr-dashboard";
              port = 7000;
            };
          };
        };
        httpRoutes.rook-ceph-rados.spec = {
          hostnames = ["rados.${domain}"];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              # TODO get actual service name
              name = "rook-ceph-radosgw";
              port = 80;
            };
          };
        };
      };
    };
  };
}
