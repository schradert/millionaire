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
  nixidy = {
    charts,
    lib,
    ...
  }: {
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
            storage.nodes = [
              {
                name = "sirver";
                devices = [
                  {name = "/dev/disk/by-id/scsi-35000c50067fb404b";}
                  {name = "/dev/disk/by-id/scsi-35000c50067fc5df3";}
                  {name = "/dev/disk/by-id/scsi-35000c50067fc640b";}
                  {name = "/dev/disk/by-id/scsi-35000c50067fcc0d3";}
                  {name = "/dev/disk/by-id/scsi-35000c50067fcc2fb";}
                  {name = "/dev/disk/by-id/scsi-35000c50067fcd9af";}
                  {name = "/dev/disk/by-id/scsi-35000c50067fe560f";}
                ];
              }
              {
                name = "octopus";
                devices = [
                  {name = "/dev/disk/by-id/scsi-36b82a720cf60ce002fd94d462aff700b";}
                  {name = "/dev/disk/by-id/scsi-36b82a720cf60ce002fd94d552bdede19";}
                  {name = "/dev/disk/by-id/scsi-36b82a720cf60ce002fd94d622ca764e8";}
                  {name = "/dev/disk/by-id/scsi-36b82a720cf60ce002fd94d6f2d66f068";}
                  {name = "/dev/disk/by-id/scsi-36b82a720cf60ce002fd94d7c2e2ed82e";}
                  {name = "/dev/disk/by-id/scsi-36b82a720cf60ce002fd94d8a2f011f94";}
                  {name = "/dev/disk/by-id/scsi-36b82a720cf60ce002fd94d962fc2bcad";}
                ];
              }
            ];
          };
          cephFileSystems = [];
          cephBlockPoolsVolumeSnapshotClass.enabled = true;
          monitoring.enabled = true;
          monitoring.createPrometheusRules = true;
        };
      };
      resources = {
        storageClasses.ceph-bucket.parameters.region = lib.mkForce "us-west-004";
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
