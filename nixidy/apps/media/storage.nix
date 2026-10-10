{...}: {
  nixidy = {...}: {
    applications.media-storage = {
      namespace = "media";
      volsync.pvcs.media-dvd = {
        title = "media-dvd";
        cacheAccessModes = ["ReadWriteOnce"];
        # Restores of the ISO library are deliberate, never automatic.
        restore = false;
      };
      # Libraries that cannot be re-downloaded from the *arr stack. Deliberately not backed up:
      # media-downloads (transient), media-movies/media-tv (re-acquirable, large).
      volsync.pvcs.media-music = {
        title = "media-music";
        cacheAccessModes = ["ReadWriteOnce"];
        restore = false;
      };
      volsync.pvcs.media-books = {
        title = "media-books";
        cacheAccessModes = ["ReadWriteOnce"];
        restore = false;
      };
      volsync.pvcs.media-audiobooks = {
        title = "media-audiobooks";
        cacheAccessModes = ["ReadWriteOnce"];
        restore = false;
      };
      volsync.pvcs.media-comics = {
        title = "media-comics";
        cacheAccessModes = ["ReadWriteOnce"];
        restore = false;
      };
      volsync.pvcs.media-podcasts = {
        title = "media-podcasts";
        cacheAccessModes = ["ReadWriteOnce"];
        restore = false;
      };
      volsync.pvcs.media-games = {
        title = "media-games";
        cacheAccessModes = ["ReadWriteOnce"];
        restore = false;
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
        # ROMs, BIOS and game installers (games-webdav.nix, docs/games.md)
        media-games = cephfsPVC "250Gi";
      };
    };
  };
}
