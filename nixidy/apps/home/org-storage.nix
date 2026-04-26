{...}: {
  nixidy = {...}: {
    applications.org-storage = {
      namespace = "home";
      resources.persistentVolumeClaims.org-files.spec = {
        accessModes = ["ReadWriteMany"];
        storageClassName = "ceph-filesystem";
        resources.requests.storage = "5Gi";
      };
    };
  };
}
