# Self-manage the app-of-apps Application.
#
# nixidy generates `Application-<name>.yaml` for every public app inside the
# appOfApps source dir, but explicitly filters the appOfApps itself out of that
# set (modules/nixidy.nix:294, `appsWithoutAppsOfApps`) — so the parent
# Application is only emitted once, by `nixidy bootstrap`. If the in-cluster
# `apps` Application is ever deleted/never-applied, ArgoCD has nothing to
# resurrect it from git, and every new child Application under
# `nixidy/generated/prod/apps/` ends up orphaned.
#
# We add the appOfApps back to its own resources.applications set so its
# manifest is committed alongside the children. The Application managing
# itself is a no-op when in sync; on a fresh cluster apply (kubectl apply -f
# Application-apps.yaml) it self-heals from then on.
{
  nixidy = {
    config,
    lib,
    ...
  }: let
    cfg = config.nixidy;
    app = config.applications.${cfg.appOfApps.name};
  in {
    applications.${cfg.appOfApps.name}.resources.applications.${cfg.appOfApps.name} = {
      metadata.name = cfg.appOfApps.name;
      spec = {
        inherit (app) project;
        source = {
          repoURL = cfg.target.repository;
          targetRevision = cfg.target.branch;
          path = lib.path.subpath.join [
            cfg.target.rootPath
            app.output.path
          ];
        };
        destination = {
          inherit (app) namespace;
          inherit (app.destination) server;
        };
        syncPolicy = {
          automated = {
            inherit (app.syncPolicy.autoSync) prune selfHeal;
          };
          syncOptions = app.syncPolicy.finalSyncOpts;
        };
      };
    };
  };
}
