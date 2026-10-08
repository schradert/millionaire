{...}: {
  nixidy = {...}: {
    applications.media-storage = {
      namespace = "media";
      volsync.pvcs.media-dvd = {
        title = "media-dvd";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      resources.persistentVolumeClaims = let
        cephfsPVC = size: {
          # Never let a sync or app removal delete library data.
          metadata.annotations."argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
          spec = {
            accessModes = ["ReadWriteMany"];
            storageClassName = "ceph-filesystem";
            resources.requests.storage = size;
          };
        };
      in {
        media-movies = cephfsPVC "500Gi";
        media-tv = cephfsPVC "100Gi";
        media-music = cephfsPVC "50Gi";
        media-books = cephfsPVC "20Gi";
        media-audiobooks = cephfsPVC "50Gi";
        media-comics = cephfsPVC "20Gi";
        media-podcasts = cephfsPVC "20Gi";
        media-downloads = cephfsPVC "50Gi";
        # Full-disc DVD backups (ISOs): the originals behind media-movies, played with menus in Kodi.
        media-dvd = cephfsPVC "1Ti";
      };
    };
  };
}
