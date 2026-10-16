{...}: {
  nixidy = {...}: {
    # Living files the Syncthing hub serves: documents and per-emulator saves. They sit in `home`
    # because a pod can only mount PVCs of its own namespace (the hub is syncthing.nix).
    applications.sync-storage = {
      namespace = "home";
      volsync.pvcs = let
        pvc = title: {
          inherit title;
          cacheAccessModes = ["ReadWriteOnce"];
          # Staggered after the 04:00 library backups, with a week of history for files that change.
          schedule = "30 3 * * *";
          retain.daily = 7;
        };
      in {
        sync-docs = pvc "sync-docs";
        sync-saves = pvc "sync-saves";
      };
      resources.persistentVolumeClaims = let
        cephfsPVC = size: {
          spec = {
            accessModes = ["ReadWriteMany"];
            storageClassName = "ceph-filesystem";
            resources.requests.storage = size;
          };
        };
      in {
        sync-docs = cephfsPVC "50Gi";
        sync-saves = cephfsPVC "50Gi";
      };
    };
  };
}
