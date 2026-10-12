{...}: {
  nixidy = {...}: {
    applications.org-storage = {
      namespace = "home";
      volsync.pvcs.org-files = {
        title = "org-files";
        cacheAccessModes = ["ReadWriteOnce"];
        # The notes folder is synced live by Syncthing; a restore is deliberate, never automatic.
        restore = false;
      };
      resources.persistentVolumeClaims.org-files.spec = {
        accessModes = ["ReadWriteMany"];
        storageClassName = "ceph-filesystem";
        resources.requests.storage = "5Gi";
      };
    };
  };
}
