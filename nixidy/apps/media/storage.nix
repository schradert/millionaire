{...}: {
  nixidy = {...}: {
    applications.media-storage = {
      namespace = "media";
      volsync.pvcs.media-dvd = {
        title = "media-dvd";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      # Libraries that cannot be re-downloaded from the *arr stack. Deliberately not backed up:
      # media-downloads (transient), media-tv and media-sports (re-acquirable, large).
      volsync.pvcs.media-music = {
        title = "media-music";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      volsync.pvcs.media-books = {
        title = "media-books";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      volsync.pvcs.media-audiobooks = {
        title = "media-audiobooks";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      volsync.pvcs.media-comics = {
        title = "media-comics";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      volsync.pvcs.media-manga = {
        title = "media-manga";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      volsync.pvcs.media-podcasts = {
        title = "media-podcasts";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      volsync.pvcs.media-games = {
        title = "media-games";
        cacheAccessModes = ["ReadWriteOnce"];
      };
      # The curated DVD MKVs: days of encoding and review, with the discs as the only other source.
      volsync.pvcs.media-movies = {
        title = "media-movies";
        cacheAccessModes = ["ReadWriteOnce"];
        # After the 04:00 backups, so the first ~470GB upload does not run beside the other seeds.
        schedule = "0 6 * * *";
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
        media-movies = cephfsPVC "600Gi";
        media-tv = cephfsPVC "100Gi";
        media-music = cephfsPVC "50Gi";
        media-books = cephfsPVC "20Gi";
        media-audiobooks = cephfsPVC "50Gi";
        media-comics = cephfsPVC "20Gi";
        # Suwayomi's CBZ downloads, the Manga library in Komga and Kavita.
        media-manga = cephfsPVC "50Gi";
        media-podcasts = cephfsPVC "20Gi";
        media-downloads = cephfsPVC "50Gi";
        # Full-disc DVD backups (ISOs): the originals behind media-movies, played with menus in Kodi.
        media-dvd = cephfsPVC "1536Gi";
        # ROMs, BIOS and game installers (games-webdav.nix, docs/games.md)
        media-games = cephfsPVC "250Gi";
        # Sportarr's library (re-acquirable, so not backed up). Ceph is small (size 2), so the quota is
        # modest and Sportarr deletes matches after SPORTARR_RETENTION_DAYS (sportarr.nix).
        media-sports = cephfsPVC "250Gi";
      };
    };
  };
}
