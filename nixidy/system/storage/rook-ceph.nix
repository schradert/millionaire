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
    # Rook takes each CSI container list as a YAML string (JSON is YAML). CPU requests sit at the observed 7d p95
    # plus headroom; memory is restated at the chart defaults because the list replaces them wholesale.
    csiResources = lib.mapAttrsToList (name: c: {
      inherit name;
      resource = {
        requests = lib.filterAttrs (_: v: v != null) {inherit (c) cpu memory;};
        limits.memory = c.limit;
      };
    });
    sidecar = {
      cpu = "20m";
      memory = "128Mi";
      limit = "256Mi";
    };
    plugin = cpu: {
      inherit cpu;
      memory = "512Mi";
      limit = "1Gi";
    };
    # Ceph daemons that hold quorum or serve clients run on the always-on nodes only. Desktops (class=desktop)
    # and burst VMs (class=vm) carry the class label and can be off; the cluster nodes carry none.
    # Rook put mon-e on falcon after chinchilla's mon failed over (2026-10-16).
    alwaysOn.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = lib.toList {
      matchExpressions = lib.toList {
        key = "node.trdos.me/class";
        operator = "DoesNotExist";
      };
    };
  in {
    # radosgw: S3 API (signed requests, no UI), so no tile and no oauth2-proxy.
    portal.apps.rados.enable = false;
    gatus.endpoints.rados = {
      url = "https://rados.${domain}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 403)"];
    };
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
            # 200m requested, 104m at p95 over 7d.
            resources.requests.cpu = "150m";
            csi.csiRBDPluginResource = builtins.toJSON (csiResources {
              driver-registrar = sidecar;
              csi-rbdplugin = plugin "50m";
              liveness-prometheus = sidecar;
            });
            csi.csiCephFSPluginResource = builtins.toJSON (csiResources {
              driver-registrar = sidecar;
              csi-cephfsplugin = plugin "50m";
              liveness-prometheus = sidecar;
            });
            csi.csiRBDProvisionerResource = builtins.toJSON (csiResources {
              csi-provisioner = sidecar;
              csi-resizer = sidecar;
              csi-attacher = sidecar;
              csi-snapshotter = sidecar;
              # The chart sets no CPU request on this one, only memory.
              csi-rbdplugin = plugin null;
              csi-omap-generator = plugin "50m";
              liveness-prometheus = sidecar;
            });
            csi.csiCephFSProvisionerResource = builtins.toJSON (csiResources {
              csi-provisioner = sidecar;
              csi-resizer = sidecar;
              csi-attacher = sidecar;
              csi-snapshotter = sidecar;
              csi-cephfsplugin = plugin "50m";
              liveness-prometheus = sidecar;
            });
            # recover_session=clean: a kernel client that the MDS blocklists (an MDS failover past the reconnect
            # window, 2026-10-15) reconnects with a fresh session instead of failing every access with EACCES until
            # its pod is recreated. Dirty data of the lost session is dropped. Applies to mounts made after the rollout.
            csi.cephFSKernelMountOptions = "ms_mode=prefer-crc,recover_session=clean";
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
          # predict_linear over 2d keeps one series per mgr pod, so after an mgr restart the
          # upstream join finds duplicates and the rule fails; aggregate the pod label away.
          fixRule = rule:
            if (rule.alert or "") == "CephPoolGrowthWarning"
            then rule // {expr = "(max by (cluster, pool_id, instance) (predict_linear(ceph_pool_percent_used[2d], 3600 * 24 * 5)) * on(cluster, pool_id, instance) group_right() ceph_pool_metadata) >= 95";}
            else rule;
          patch = resource:
            if (resource.kind or "") == "PrometheusRule"
            then resource // {spec = resource.spec // {groups = map (g: g // {rules = map fixRule g.rules;}) resource.spec.groups;};}
            else if (resource.kind or "") == "CephBlockPool"
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
                    # Rook's default anti-affinity is only a preference, and both daemons landed on octopus; when that
                    # node stalled (2026-10-15) the standby died with the active MDS, the replacement missed the
                    # clients' reconnect window and they were blocklisted. Keep the pair on different hosts.
                    # CPU request at 2x the 7d p95 (~0.085 cores at worst); the chart's 4Gi memory request sizes the MDS cache.
                    metadataServer = lib.recursiveUpdate resource.spec.metadataServer {
                      resources.requests.cpu = "200m";
                      placement.nodeAffinity = alwaysOn;
                      placement.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = lib.toList {
                        labelSelector.matchLabels = {
                          app = "rook-ceph-mds";
                          rook_file_system = "ceph-filesystem";
                        };
                        topologyKey = "kubernetes.io/hostname";
                      };
                    };
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
            # CPU requests at the 7d p95 plus headroom (mon ~47m, mgr ~78m, the rest idle); the chart's memory
            # requests and limits are left alone. They merge with the chart defaults, so only CPU is restated.
            resources = lib.mapAttrs (_: cpu: {requests.cpu = cpu;}) {
              mon = "150m";
              mgr = "200m";
              mgr-sidecar = "75m";
              logcollector = "20m";
              crashcollector = "20m";
            };
            # Mon stores are hostPath /var/lib/rook on the node's root disk, and sirver's is SMART-failing, so mons
            # also stay off it (Rook put mon-f there after #1074, 2026-10-16). mgr/mds/rgw keep no state on the disk.
            # All expressions in a term must match. Remove with README todo 33 once sirver's disk is replaced.
            placement.mon.nodeAffinity = lib.recursiveUpdate alwaysOn {
              requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = lib.toList {
                matchExpressions = [
                  {
                    key = "node.trdos.me/class";
                    operator = "DoesNotExist";
                  }
                  {
                    key = "kubernetes.io/hostname";
                    operator = "NotIn";
                    values = ["sirver"];
                  }
                ];
              };
            };
            placement.mgr.nodeAffinity = alwaysOn;
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
                # Bay 7 (serial 6XS41YTD, scsi-35000c50067fb404b) is SMART-failing:
                # it was osd.7, now in retiredOsds below (purge + zap). Add the
                # replacement drive's by-id here after the swap (manual-steps 5).
                # Bay 2 (6XS42DQ9, scsi-35000c50067fcd9af) was osd.0: it is retired
                # below so the disk can become the new root (docs/node-standard.md,
                # "sirver reinstall plan").
                devices = [
                  {name = "/dev/disk/by-id/scsi-35000c50067fc5df3";}
                  {name = "/dev/disk/by-id/scsi-35000c50067fc640b";}
                  {name = "/dev/disk/by-id/scsi-35000c50067fcc0d3";}
                  {name = "/dev/disk/by-id/scsi-35000c50067fcc2fb";}
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
              {
                # The Toshiba 4 TB data disk (X1Q0A2MPFYXG). Rook skips a disk that still has partitions, so it is
                # used only after `data` is retired and the disk wiped (docs/node-standard.md, "sirver reinstall plan").
                name = "falcon";
                devices = [{name = "/dev/disk/by-id/wwn-0x5000039b38dbee27";}];
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
                # CPU request at 2x the 7d p95 (~0.08 cores); bursts to ~0.36 are absorbed by the unlimited CPU.
                resources = {
                  limits.memory = "2Gi";
                  requests = {
                    cpu = "200m";
                    memory = "1Gi";
                  };
                };
                # The gateway runs on the host network and binds 0.0.0.0:80, which
                # collides with the internal-gateway relays (100.64.0.4:80/443 on bonobo,
                # 100.64.0.5:80 on chinchilla).
                placement.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = lib.toList {
                  matchExpressions = [
                    {
                      key = "kubernetes.io/hostname";
                      operator = "NotIn";
                      values = ["bonobo" "chinchilla"];
                    }
                    {
                      key = "node.trdos.me/class";
                      operator = "DoesNotExist";
                    }
                  ];
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
      resources = let
        # Retired OSDs: id, the node that holds the disk, and the disk by-id.
        retiredOsds = [
          {
            id = 7;
            node = "sirver";
            device = "/dev/disk/by-id/scsi-35000c50067fb404b";
          }
          {
            id = 0;
            node = "sirver";
            device = "/dev/disk/by-id/scsi-35000c50067fcd9af";
          }
        ];
      in {
        # Hooks are not live resources, so a change to retiredOsds alone is no
        # diff and would never sync (see nixidy/system/cicd/bootstrap.nix). This
        # tracked ConfigMap makes it one.
        configMaps.rook-ceph-retired-osds.data = {
          retired = builtins.toJSON retiredOsds;
          # Bump to rerun the hooks after a change to their scripts or images.
          revision = "3";
        };
        # OSDs retired in git: every sync runs this hook, which takes each id
        # through out → safe-to-destroy → down (noup so the daemon stays down)
        # → `rook ceph osd remove` (deletes the Deployment, purges the OSD and
        # its CRUSH entry). An id that no longer exists is a no-op, so the list
        # is a durable statement of what must not be in the cluster. Drop the
        # id (and the device above) once the drive is physically replaced.
        # osd.7 (sirver bay 7, serial 6XS41YTD, SMART-failing): the owner chose
        # to zap it (2026-10-12). Rook re-activates an OSD whose bluestore label
        # is still on the disk even when the device is not in the node list, so
        # the purge below is followed by `rook-ceph-zap-devices`, which wipes the
        # disk on the node once the OSD is gone.
        jobs =
          {
            rook-ceph-remove-osds = let
              removedOsds = map (o: o.id) retiredOsds;
              script = ''
                set -u
                mkdir -p /etc/ceph
                cat > /etc/ceph/ceph.conf <<EOF
                [global]
                fsid = $ROOK_FSID
                mon_host = $(echo "$ROOK_MON_ENDPOINTS" | tr ',' '\n' | cut -d= -f2 | paste -sd, -)
                EOF
                install -m 600 /etc/ceph-admin/keyring /etc/ceph/keyring
                rc=0
                for id in ${lib.concatMapStringsSep " " toString removedOsds}; do
                  if ! ceph osd find "$id" >/dev/null 2>&1; then
                    echo "osd.$id: not in the cluster, nothing to do"
                    continue
                  fi
                  ceph osd out "$id"
                  # A down OSD (one that kept the noup flag from an earlier purge,
                  # say) never reports stats, so safe-to-destroy answers EAGAIN
                  # forever; once every PG is active+clean its data is elsewhere
                  # and the removal is forced. The balancer is paused meanwhile so
                  # it does not keep adding remaps during the drain.
                  ceph balancer off
                  force=false
                  while true; do
                    if ceph osd safe-to-destroy "osd.$id" >/dev/null 2>&1; then break; fi
                    clean=$(ceph pg stat | grep -oE "[0-9]+ active\+clean" | head -1 | cut -d" " -f1)
                    total=$(ceph pg stat | grep -oE "^[0-9]+ pgs" | cut -d" " -f1)
                    if [ -n "$clean" ] && [ "$clean" = "$total" ] && ceph osd dump | grep -qE "^osd.$id down out "; then
                      echo "osd.$id: down, out, every PG active+clean: forcing the removal"
                      force=true
                      break
                    fi
                    echo "osd.$id: waiting for its data to migrate ($clean/$total PGs clean)"
                    sleep 30
                  done
                  ceph osd add-noup "osd.$id"
                  ceph osd down "$id"
                  sleep 5
                  rook ceph osd remove --osd-ids "$id" --preserve-pvc false --force-osd-removal "$force" || rc=$?
                  ceph osd rm-noup "osd.$id" 2>/dev/null || true
                  ceph balancer on
                done
                exit $rc
              '';
            in {
              metadata.annotations = {
                "argocd.argoproj.io/hook" = "PostSync";
                "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
                "argocd.argoproj.io/sync-wave" = "0";
              };
              spec = {
                backoffLimit = 3;
                # A drain on these HDD nodes can take most of a day.
                activeDeadlineSeconds = 86400;
                template.spec = {
                  restartPolicy = "OnFailure";
                  serviceAccountName = "rook-ceph-purge-osd";
                  containers = lib.toList {
                    name = "remove-osds";
                    image = with pinned.images.rook-ceph; "${repository}:${tag}@${digest}";
                    command = ["/bin/sh" "-c" script];
                    env = let
                      fromSecret = name: key: {
                        inherit name;
                        valueFrom.secretKeyRef = {
                          name = "rook-ceph-mon";
                          inherit key;
                        };
                      };
                    in [
                      {
                        name = "POD_NAMESPACE";
                        valueFrom.fieldRef.fieldPath = "metadata.namespace";
                      }
                      {
                        name = "ROOK_MON_ENDPOINTS";
                        valueFrom.configMapKeyRef = {
                          name = "rook-ceph-mon-endpoints";
                          key = "data";
                        };
                      }
                      (fromSecret "ROOK_CEPH_USERNAME" "ceph-username")
                      (fromSecret "ROOK_CEPH_SECRET" "ceph-secret")
                      (fromSecret "ROOK_FSID" "fsid")
                      {
                        name = "ROOK_CONFIG_DIR";
                        value = "/var/lib/rook";
                      }
                      {
                        name = "ROOK_CEPH_CONFIG_OVERRIDE";
                        value = "/etc/rook/config/override.conf";
                      }
                    ];
                    volumeMounts = [
                      {
                        name = "ceph-conf";
                        mountPath = "/etc/ceph";
                      }
                      {
                        name = "rook-config";
                        mountPath = "/var/lib/rook";
                      }
                      {
                        name = "admin-keyring";
                        mountPath = "/etc/ceph-admin";
                        readOnly = true;
                      }
                    ];
                  };
                  volumes = [
                    {
                      name = "ceph-conf";
                      emptyDir = {};
                    }
                    {
                      name = "rook-config";
                      emptyDir = {};
                    }
                    {
                      name = "admin-keyring";
                      secret.secretName = "rook-ceph-admin-keyring";
                    }
                  ];
                };
              };
            };
          }
          // lib.listToAttrs (map (node: let
            # After the purge (wave 1): wipe each retired disk on its node so Rook
            # cannot re-activate the OSD from the bluestore label. One privileged Job
            # per node. A disk is zapped only if it still carries a bluestore label
            # whose fsid is this cluster's and whose osd id is no longer in the
            # cluster; anything else is left alone (and reported) — the purge above
            # must have finished first. Idempotent: a wiped disk has no label.
            disks = lib.filter (o: o.node == node) retiredOsds;
            script = ''
              set -u
              mkdir -p /etc/ceph
              cat > /etc/ceph/ceph.conf <<EOF
              [global]
              fsid = $ROOK_FSID
              mon_host = $(echo "$ROOK_MON_ENDPOINTS" | tr ',' '\n' | cut -d= -f2 | paste -sd, -)
              EOF
              install -m 600 /etc/ceph-admin/keyring /etc/ceph/keyring
              rc=0
              for dev in ${lib.concatMapStringsSep " " (o: o.device) disks}; do
                if [ ! -e "$dev" ]; then echo "$dev: not present on $(hostname), skipping"; continue; fi
                # blkid sees the signature even while the disk is open; show-label does not.
                if [ "$(blkid -o value -s TYPE "$dev" 2>/dev/null)" != "ceph_bluestore" ]; then
                  echo "$dev: no bluestore signature, nothing to zap"
                  continue
                fi
                if ! label=$(ceph-bluestore-tool show-label --dev "$dev" 2>&1); then
                  echo "$dev: cannot read the bluestore label (in use?): $label"; rc=1; continue
                fi
                fsid=$(echo "$label" | sed -n 's/.*"ceph_fsid": "\([^"]*\)".*/\1/p' | head -1)
                id=$(echo "$label" | sed -n 's/.*"whoami": "\([^"]*\)".*/\1/p' | head -1)
                if [ "$fsid" != "$ROOK_FSID" ]; then echo "$dev: fsid $fsid is not this cluster, refusing"; rc=1; continue; fi
                if ceph osd find "$id" >/dev/null 2>&1; then echo "$dev: osd.$id still exists, purge first"; rc=1; continue; fi
                echo "$dev: osd.$id is gone, zapping"
                ceph-volume lvm zap --destroy "$dev" || rc=$?
              done
              exit $rc
            '';
          in
            lib.nameValuePair "rook-ceph-zap-devices-${node}" {
              metadata.annotations = {
                "argocd.argoproj.io/hook" = "PostSync";
                "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
                "argocd.argoproj.io/sync-wave" = "1";
              };
              spec = {
                backoffLimit = 1;
                activeDeadlineSeconds = 1800;
                template.spec = {
                  restartPolicy = "OnFailure";
                  serviceAccountName = "rook-ceph-purge-osd";
                  nodeSelector."kubernetes.io/hostname" = node;
                  hostPID = true;
                  containers = lib.toList {
                    name = "zap";
                    # The ceph image: ceph-volume, ceph-bluestore-tool and blkid (the
                    # rook image has none of them, which read as "no label").
                    image = with pinned.images.ceph; "${repository}:${tag}@${digest}";
                    command = ["/bin/sh" "-c" script];
                    securityContext.privileged = true;
                    env = let
                      fromSecret = name: key: {
                        inherit name;
                        valueFrom.secretKeyRef = {
                          name = "rook-ceph-mon";
                          inherit key;
                        };
                      };
                    in [
                      {
                        name = "ROOK_MON_ENDPOINTS";
                        valueFrom.configMapKeyRef = {
                          name = "rook-ceph-mon-endpoints";
                          key = "data";
                        };
                      }
                      (fromSecret "ROOK_FSID" "fsid")
                    ];
                    volumeMounts = [
                      {
                        name = "dev";
                        mountPath = "/dev";
                      }
                      {
                        name = "ceph-conf";
                        mountPath = "/etc/ceph";
                      }
                      {
                        name = "admin-keyring";
                        mountPath = "/etc/ceph-admin";
                        readOnly = true;
                      }
                    ];
                  };
                  volumes = [
                    {
                      name = "dev";
                      hostPath.path = "/dev";
                    }
                    {
                      name = "ceph-conf";
                      emptyDir = {};
                    }
                    {
                      name = "admin-keyring";
                      secret.secretName = "rook-ceph-admin-keyring";
                    }
                  ];
                };
              };
            }) (lib.unique (map (o: o.node) retiredOsds)));
        # The chart's Ceph alert rules (health, device failure, slow ops), selected by Prometheus.
        prometheusRules.prometheus-ceph-rules.metadata.labels.release = "prometheus";
        # The chart has no rule for blocklisting: an evicted CephFS client keeps its mount but every access fails
        # until the pod is recreated, and nothing else notices.
        prometheusRules.ceph-clients.metadata.labels.release = "prometheus";
        prometheusRules.ceph-clients.spec.groups = lib.toList {
          name = "ceph-clients";
          rules = lib.toList {
            alert = "CephClientsBlocklisted";
            # Expired entries lower the count, so only growth fires.
            expr = "increase(ceph_cluster_osd_blocklist_count[15m]) > 0";
            labels.severity = "warning";
            annotations.summary = "Ceph blocklisted clients";
            annotations.description = "The blocklist grew by {{ $value }}: the MDS evicted CephFS clients (or a client was fenced). Mounts on the affected nodes may fail with EACCES until their pods restart; compare `ls` on each CephFS mount, or `dmesg | grep blocklisted` on the nodes.";
          };
        };
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
              # Rook names the RGW Service rook-ceph-rgw-<cephObjectStores name>.
              name = "rook-ceph-rgw-ceph-objectstore";
              port = 80;
            };
          };
        };
      };
    };
  };
}
