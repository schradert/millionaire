{config, ...}: let
  bucketName = "${builtins.replaceStrings ["."] ["-"] config.canivete.meta.domain}--volsync";
in {
  nixidy = {
    can,
    config,
    lib,
    pinned,
    ...
  }: {
    applications.volsync-crds.namespace = "kube-system";
    canivete.crds.volsync = {
      application = "volsync-crds";
      install = true;
      prefix = "config/crd/bases";
      src = pinned.volsync;
    };
    applications.volsync = {
      namespace = "storage";
      helm.releases.volsync = {
        chart = pinned.charts.volsync;
        values =
          {manageCRDs = false;}
          // lib.genAttrs ["image" "rclone" "restic" "rsync" "rsync-tls" "syncthing"] (_: {
            image = with pinned.images.volsync; "${repository}:${tag}@${digest}";
          });
      };
    };
    # Movers mount the live PVC (copyMethod Direct). Unprivileged, a mover needs an fsGroup that kubelet then applies
    # as a recursive chown of the workload's volume (re-owning it away from the app's own gid on every backup).
    # Privileged movers run as root with no fsGroup: nothing is chowned, any ownership is readable, and restores
    # keep the ownership recorded in the snapshot. VolSync grants that per namespace, so annotate each one that
    # holds a backed-up PVC.
    applications.namespaces.resources.namespaces = lib.genAttrs (lib.unique (lib.filter (ns: ns != null) (
      lib.mapAttrsToList (_: app: app.namespace) (lib.filterAttrs (_: app: app.volsync.pvcs != null && app.volsync.pvcs != {}) config.applications)
    ))) (_: {metadata.annotations."volsync.backube/privileged-movers" = "true";});
    # Attaches VolSync replication mechanisms to target PVCs and back up to Backblaze B2
    nixidy.applicationImports = [
      ({
        config,
        name,
        ...
      }: {
        options.volsync = {
          enable = can.enable "Volsync replication of PVCs" {default = config.volsync.pvcs != null;};
          pvcs = can.attrs.submodule "Name of PVCs to replicate and back up" ({config, ...}: {
            options = {
              title = can.str "Name of PVC eventually created" {};
              path = can.list.str "Delimited location to inject dataSourceRef for ReplicationDestination" {
                default = ["persistentVolumeClaims" config.title];
              };
              inject = can.enable "Inject dataSourceRef into a PVC" {};
              restore = can.enable "ReplicationDestination that restores the latest snapshot into the PVC" {default = true;};
              cacheAccessModes = can.list.str "Mover cache access modes (RWX sources need ReadWriteOnce on ceph-block)" {default = [];};
              schedule = can.str "Cron schedule of the backup" {default = "0 4 * * *";};
              retain = lib.mkOption {
                description = "Snapshots kept per period; pruned every 8 days";
                default = {};
                type = lib.types.submodule {
                  options = lib.genAttrs ["daily" "weekly" "monthly" "yearly"] (period: can.int "${period} snapshots to keep" {default = 1;});
                };
              };
            };
          });
        };
        config = lib.mkIf config.volsync.enable {
          resources = lib.mkMerge (lib.flip lib.mapAttrsToList config.volsync.pvcs (pvcName: pvc: let
            inherit (pvc) title inject path cacheAccessModes restore schedule retain;
            cache = lib.optionalAttrs (cacheAccessModes != []) {inherit cacheAccessModes;};
            region = "us-west-004";
            repository = "volsync--${name}--${pvcName}";
          in
            lib.mkMerge [
              # Some services use operators that allow configuration injection into PersistentVolumeClaim templates
              # Some still don't offer ways to inject so we have to do this manually
              (lib.mkIf inject (lib.setAttrByPath path {
                spec.dataSourceRef = {
                  kind = "ReplicationDestination";
                  apiGroup = "volsync.backube";
                  name = "${repository}-dst";
                };
              }))
              {
                externalSecrets.${repository}.spec = {
                  secretStoreRef.name = "bitwarden";
                  secretStoreRef.kind = "ClusterSecretStore";
                  data = [
                    {
                      secretKey = "restic";
                      remoteRef.key = "volsync/restic/password";
                    }
                    {
                      secretKey = "id";
                      remoteRef.key = "backblaze/bucket/application_key_id";
                    }
                    {
                      secretKey = "password";
                      remoteRef.key = "backblaze/bucket/application_key";
                    }
                  ];
                  target.template.data = {
                    RESTIC_REPOSITORY = "s3:https://s3.${region}.backblazeb2.com/${bucketName}/${repository}";
                    RESTIC_PASSWORD = "{{ .restic }}";
                    AWS_ACCESS_KEY_ID = "{{ .id }}";
                    AWS_SECRET_ACCESS_KEY = "{{ .password }}";
                    AWS_DEFAULT_REGION = region;
                  };
                };
                # Copy on `schedule` (4am daily by default), pruning every 8 days down to `retain`
                replicationSources."${repository}-src".spec = {
                  sourcePVC = title;
                  trigger.schedule = schedule;
                  restic =
                    cache
                    // {
                      copyMethod = "Direct";
                      pruneIntervalDays = 8;
                      inherit repository;
                      inherit retain;
                    };
                };
                replicationDestinations = lib.mkIf restore {
                  "${repository}-dst".spec = {
                    # Override this to track restoration
                    trigger.manual = lib.mkDefault "1";
                    restic =
                      cache
                      // {
                        copyMethod = "Direct";
                        destinationPVC = title;
                        inherit repository;
                      };
                  };
                };
              }
            ]));
        };
      })
    ];
  };
}
