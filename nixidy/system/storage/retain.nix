{
  nixidy = {
    can,
    lib,
    ...
  }: {
    # Stateful data outlives its app. Every Application carries the resources finalizer, so removing or renaming one
    # deletes what it deployed; a CNPG Cluster owns its PVCs (ownerReferences), so deleting the Cluster deletes the
    # volumes too. An app lists `deletable` names to opt out (pure caches).
    nixidy.applicationImports = [
      ({config, ...}: {
        options.deletable = can.list.str "PersistentVolumeClaims and CNPG Clusters removed with the app instead of kept" {default = [];};
        config.defaults = map (gvk:
          gvk
          // {
            default = {name, ...}: {
              config = lib.mkIf (!lib.elem name config.deletable) {
                metadata.annotations."argocd.argoproj.io/sync-options" = lib.mkDefault "Prune=false,Delete=false";
              };
            };
          }) [
          {
            group = "core";
            version = "v1";
            kind = "PersistentVolumeClaim";
          }
          {
            group = "postgresql.cnpg.io";
            version = "v1";
            kind = "Cluster";
          }
        ];
      })
    ];
  };
}
