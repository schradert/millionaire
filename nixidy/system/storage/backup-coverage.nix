# Every PVC has an off-site path, or a reason it does not. The reasons are the `volsync.exempt` list below; the alert
# PVCWithoutBackup (rendered from that list) fires for any other claim that is neither a VolSync source (`volsync.pvcs`
# on an app) nor a CNPG volume (those are backed up by barman, postgres.nix). The daily alert digest mails it, so a
# new unbacked volume shows up without an audit. docs/pvc-and-postgres-restore.md has the coverage table.
{...}: {
  nixidy = {
    config,
    lib,
    ...
  }: let
    entries =
      lib.mapAttrsToList (key: reason: let
        parts = lib.splitString "/" key;
      in {
        inherit reason;
        namespace = lib.elemAt parts 0;
        pvc = lib.elemAt parts 1;
      })
      config.volsync.exempt;
    exempt = lib.concatStringsSep " or " (lib.mapAttrsToList (namespace: es: ''kube_persistentvolumeclaim_info{namespace="${namespace}",persistentvolumeclaim=~"${lib.concatMapStringsSep "|" (e: e.pvc) es}"}'') (lib.groupBy (e: e.namespace) entries));
  in {
    options.volsync.exempt = lib.mkOption {
      description = "PersistentVolumeClaims with no off-site copy, as \"<namespace>/<name regex>\" = reason. Only for volumes that are rebuilt from elsewhere or hold nothing worth keeping; say which.";
      default = {};
      type = lib.types.attrsOf lib.types.str;
    };
    config = {
      volsync.exempt = {
        # Caches: re-downloaded or rebuilt on use.
        "ai/(ollama|vllm|heretic-cache)" = "Model weights, downloaded again on first use (apps disabled until a GPU node exists)";
        "ai/heretic-output" = "Empty (checked 2026-10-17) and the app is disabled; heretic.nix already declares its VolSync source for when it returns";
        "media/libretranslate" = "Translation models, downloaded again at start";
        "media/jellyfin-cache" = "Image and transcode cache, rebuilt by Jellyfin";
        "cicd/(deps-update-nix|image-build-nix)" = "Nix store caches of the CI runners, rebuilt from the binary caches";
        "cicd/data-harbor-trivy-0" = "Trivy vulnerability database, downloaded again by the scanner";
        "observability/storage-mimir-(compactor|store-gateway)-0" = "Compactor scratch and store-gateway index headers, both rebuilt from the bucket (which rgwOffsite mirrors)";
        "workspaces/.*-nix" = "Single-user Nix store of a Coder workspace, seeded from the workspace image";
        # In-flight or re-acquirable data.
        "media/media-downloads" = "In-flight downloads, queued again by the *arr apps";
        "media/media-sports" = "Sportarr's library: re-acquirable, and empty today";
        "media/dvd-rip-work" = "Rip scratch space; the finished MKVs land in media-movies, which is backed up";
        "home/frigate-media" = "Rolling camera recordings (7-14 days): backing them up costs more than they are worth. Clips, snapshots and exports are separate volumes and are backed up";
        # A logical copy stands in for the volume.
        "media/tracearr-db" = "TimescaleDB data directory: a file copy of a live database is not a backup. Tracearr's own daily dump goes to the tracearr-backup volume, which is backed up";
      };
      applications.volsync.resources.prometheusRules.volsync-coverage = {
        metadata.labels.release = "prometheus";
        spec.groups = lib.toList {
          name = "volsync-coverage";
          rules = [
            {
              alert = "PVCWithoutBackup";
              expr = ''
                kube_persistentvolumeclaim_info{namespace!="backup-verify",persistentvolumeclaim!~"volsync-(src|dst)-.*|dr-scratch-.*"}
                unless on (namespace, persistentvolumeclaim) volsync_replicationsource_info
                unless on (namespace, persistentvolumeclaim) kube_persistentvolumeclaim_labels{label_cnpg_io_cluster!=""}
                unless on (namespace, persistentvolumeclaim) (${exempt})
              '';
              "for" = "1h";
              labels.severity = "warning";
              annotations = {
                summary = "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} has no off-site backup";
                description = ''
                  No VolSync ReplicationSource targets it and it is not a CNPG volume. Add `volsync.pvcs.<name>.title = "{{ $labels.persistentvolumeclaim }}"` to its app,
                  or list it in `volsync.exempt` (nixidy/system/storage/backup-coverage.nix) with the reason it needs none.
                '';
              };
            }
            {
              alert = "BackupCoverageBlind";
              expr = "absent(volsync_replicationsource_info)";
              "for" = "30m";
              labels.severity = "warning";
              annotations = {
                summary = "No volsync_replicationsource_info series: PVCWithoutBackup cannot tell which volumes are backed up";
                description = "kube-state-metrics lists ReplicationSources through customResourceState (nixidy/system/observability/kube-state-metrics.nix). Check its logs and RBAC.";
              };
            }
          ];
        };
      };
    };
  };
}
