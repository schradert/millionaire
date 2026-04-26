{...}: {
  nixidy = {...}: {
    applications.media-storage = {
      namespace = "media";
      resources.persistentVolumeClaims = let
        cephfsPVC = size: {
          spec = {
            accessModes = ["ReadWriteMany"];
            storageClassName = "ceph-filesystem";
            resources.requests.storage = size;
          };
        };
      in {
        media-movies = cephfsPVC "100Gi";
        media-tv = cephfsPVC "100Gi";
        media-music = cephfsPVC "50Gi";
        media-books = cephfsPVC "20Gi";
        media-audiobooks = cephfsPVC "50Gi";
        media-comics = cephfsPVC "20Gi";
        media-podcasts = cephfsPVC "20Gi";
        media-downloads = cephfsPVC "50Gi";
      };
    };
  };
}
