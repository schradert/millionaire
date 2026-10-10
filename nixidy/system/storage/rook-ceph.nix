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
    pinned,
    lib,
    ...
  }: let
    replicas = {
      size = 2;
      requireSafeReplicaSize = false;
    };
  in {
    gatus.endpoints.rook-ceph = {
      url = "https://${subdomain}";
      group = "internal";
    };
    applications.rook-ceph = {
      namespace = "storage";
      helm.releases.rook-ceph-operator = {
        chart = pinned.charts.rook-ceph;
        values = lib.mkMerge [
          {
            image.tag = with pinned.images.rook-ceph; "${tag}@${digest}";
            csi.cephcsi.tag = with pinned.images.cephcsi; "${tag}@${digest}";
            csi.registrar.tag = with pinned.images.csi-node-driver-registrar; "${tag}@${digest}";
            csi.provisioner.tag = with pinned.images.csi-provisioner; "${tag}@${digest}";
            csi.snapshotter.tag = with pinned.images.csi-snapshotter; "${tag}@${digest}";
            csi.attacher.tag = with pinned.images.csi-attacher; "${tag}@${digest}";
            csi.resizer.tag = with pinned.images.csi-resizer; "${tag}@${digest}";
            csi.csiAddons.tag = with pinned.images.csiaddons-sidecar; "${tag}@${digest}";
            ceph-csi-operator.controllerManager.manager.image.tag = with pinned.images.ceph-csi-operator; "${tag}@${digest}";
            csi.cephFSKernelMountOptions = "ms_mode=prefer-crc";
            csi.enableCephfsDriver = true;
            csi.enableCephfsSnapshotter = true;
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
      # FIXME only 2 hosts have OSDs, so every replicated pool is size 2 (min_size stays at Ceph's
      # default of 1). Add a 3rd OSD host and restore size 3 with requireSafeReplicaSize.
      helm.releases.rook-ceph-cluster = {
        # The chart's block pool and filesystem lists carry their StorageClass wiring, so patch the
        # rendered pools instead of restating the lists.
        transformer = let
          withReplicas = pool: pool // {replicated = (pool.replicated or {}) // replicas;};
          patch = resource:
            if (resource.kind or "") == "CephBlockPool"
            then resource // {spec = withReplicas resource.spec;}
            else if (resource.kind or "") == "CephFilesystem"
            then
              resource
              // {
                spec =
                  resource.spec
                  // {
                    metadataPool = withReplicas resource.spec.metadataPool;
                    dataPools = map withReplicas resource.spec.dataPools;
                  };
              }
            else resource;
          # The operator creates .mgr itself at size 3 unless Rook is given this CR
          builtinMgr = {
            apiVersion = "ceph.rook.io/v1";
            kind = "CephBlockPool";
            metadata = {
              name = "builtin-mgr";
              namespace = "storage";
            };
            spec = {
              name = ".mgr";
              failureDomain = "host";
              replicated = replicas;
            };
          };
        in
          resources: map patch resources ++ [builtinMgr];
        chart = pinned.charts.rook-ceph-cluster;
        values = {
          cephImage.tag = with pinned.images.ceph; "${tag}@${digest}";
          operatorNamespace = "storage";
          cephClusterSpec = {
            cephConfig.global = {
              bdev_enable_discard = "true";
              bdev_async_discard_threads = "1";
              osd_class_update_on_start = "false";
              device_failure_prediction_mode = "local";
            };
            # Recovery/backfill (e.g. draining an out OSD) yields to client IO.
            cephConfig.osd.osd_mclock_profile = "high_client_ops";
            cleanupPolicy.wipeDevicesFromOtherClusters = true;
            csi.readAffinity.enabled = true;
            # Prometheus only selects monitors and rules labelled release=prometheus;
            # without this the operator's ServiceMonitors are never scraped.
            labels.monitoring.release = "prometheus";
            dashboard.urlPrefix = "/";
            dashboard.ssl = false;
            dashboard.prometheusEndpoint = "http" + "://prometheus-operated.observability.svc.cluster.local:9090";
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
          # Replaces the chart default list, so the full store is restated.
          cephObjectStores = lib.toList {
            name = "ceph-objectstore";
            spec = {
              metadataPool = {
                failureDomain = "host";
                replicated = {inherit (replicas) size requireSafeReplicaSize;};
              };
              # Erasure coding 2+1 needs 3 hosts; replicated is the only option with 2 OSD hosts.
              dataPool = {
                failureDomain = "host";
                replicated = {inherit (replicas) size requireSafeReplicaSize;};
                parameters.bulk = "true";
              };
              preservePoolsOnDelete = true;
              gateway = {
                port = 80;
                instances = 1;
                priorityClassName = "system-cluster-critical";
                resources = {
                  limits.memory = "2Gi";
                  requests = {
                    cpu = "1000m";
                    memory = "1Gi";
                  };
                };
                # The gateway runs on the host network and binds 0.0.0.0:80, which
                # collides with the internal-gateway relay (100.64.0.4:80/443) on bonobo.
                placement.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = lib.toList {
                  matchExpressions = lib.toList {
                    key = "kubernetes.io/hostname";
                    operator = "NotIn";
                    values = ["bonobo"];
                  };
                };
              };
            };
            storageClass = {
              enabled = true;
              name = "ceph-bucket";
              reclaimPolicy = "Delete";
              volumeBindingMode = "Immediate";
              parameters.region = "us-east-1";
            };
            ingress.enabled = false;
          };
          cephBlockPoolsVolumeSnapshotClass.enabled = true;
          monitoring.enabled = true;
          monitoring.createPrometheusRules = true;
        };
      };
      resources = {
        # The chart's Ceph alert rules (health, device failure, slow ops), selected by Prometheus.
        prometheusRules.prometheus-ceph-rules.metadata.labels.release = "prometheus";
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
