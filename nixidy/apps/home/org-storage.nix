{...}: {
  nixidy = {...}: {
    applications.org-storage = {
      namespace = "home";
      volsync.pvcs.org-files = {
        title = "org-files";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      resources.persistentVolumeClaims.org-files.spec = {
        accessModes = ["ReadWriteMany"];
        storageClassName = "ceph-filesystem";
        resources.requests.storage = "5Gi";
      };
    };
  };
}
