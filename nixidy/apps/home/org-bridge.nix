# One org-bridge per person in `syncthing.users` (modules/syncthing.nix) that has an `org` folder: their hub's
# org folder (nixidy/apps/home/syncthing.nix) exported one way to the calendar `org` of their own Baïkal DAV
# user (nixidy/apps/home/baikal.nix: one per Keycloak admin/family user, so a person here must be one). The
# owner's keeps the names the single org-bridge had (app `org-bridge`, PVC `org-files`); everyone else's is
# `org-bridge-<user>` on their PVC `syncthing-<user>-org`.
{config, ...}: let
  inherit (config.canivete.meta) domain people;
  inherit (config) syncthing;
in {
  nixidy = {
    charts,
    config,
    lib,
    pinned,
    ...
  }: let
    sync = import ../../../lib/syncthing.nix {inherit lib;};
    nameOf = sync.names {
      owner = people.me;
      inherit domain;
    };
    # Keycloak users that get a DAV user (the same set as baikal.nix)
    davUsers = lib.concatMap (u: let
      d = u.spec.definition;
    in
      lib.optional (lib.any (g: lib.elem g (d.groups or [])) ["family" "admin"]) d.username)
    (lib.attrValues config.applications.keycloak.resources.keycloakUsers);
    # State DB lives in an emptyDir — org files are the source of truth, so a restart
    # just triggers a full reconciliation against CalDAV, which is idempotent by design.
    # The DB file only appears once the worker finishes that initial reconciliation;
    # probe it to detect a wedged startup.
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.exec.command = ["sh" "-c" "test -f /var/lib/org-bridge/state.db"];
    };
    bridge = user: table: let
      n = nameOf user;
      i = n.bridge;
      org = table.folders.org;
      # baikal.nix's Secret holding the DAV user's generated password
      davSecret = "baikal-user-${n.slug}";
    in {
      # The checks sit on a leaf: they read the Keycloak users, which the application set itself must not wait for.
      namespace = assert lib.assertMsg (lib.elem user davUsers) "syncthing.users.${user} needs a Keycloak user in the admin or family group (nixidy/apps/identity/keycloak-operator.nix): org-bridge logs in to Baïkal as that DAV user";
      assert lib.assertMsg (org.hub.volume == "org") "syncthing.users.${user}.folders.org must be on the hub volume `org` (org-bridge mounts that PVC)"; "home";
      helm.releases.${i} = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.${i} = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.org-bridge = {
              image = pinned.images.org-bridge;
              resources.requests = {
                cpu = "25m";
                memory = "32Mi";
              };
              env = {
                ORG_DIR = "/org${lib.optionalString (org.hub.dir != "") "/${org.hub.dir}"}";
                STATE_DB_PATH = "/var/lib/org-bridge/state.db";
                SYNCTHING_URL = "http://${n.instance}.home.svc.cluster.local:8384";
                CALDAV_URL = "http://baikal.home.svc.cluster.local:80/dav.php/calendars/${user}/org/";
                # The same keywords as Emacs (lib/org.nix).
                ORG_TODO_KEYWORDS = (import ../../../lib/org.nix).todoKeywords;
                RUST_LOG = "info";
              };
              envFrom = [{secretRef.name = i;}];
              probes.liveness = probe {};
              probes.readiness = probe {};
              probes.startup = probe {
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };
          persistence = {
            org-files = {
              type = "persistentVolumeClaim";
              existingClaim = n.claim "org";
              advancedMounts.${i}.org-bridge = [
                {
                  path = "/org";
                  readOnly = true;
                }
              ];
            };
            state = {
              type = "emptyDir";
              advancedMounts.${i}.org-bridge = [{path = "/var/lib/org-bridge";}];
            };
          };
        };
      };
      # Credentials generated in-cluster for the person's syncthing and their Baïkal user.
      resources.externalSecrets.${i}.spec = {
        secretStoreRef.name = "kubernetes-home";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data = {
          SYNCTHING_API_KEY = "{{ .syncthing_key }}";
          CALDAV_USERNAME = user;
          CALDAV_PASSWORD = "{{ .caldav_password }}";
        };
        data = [
          {
            secretKey = "syncthing_key";
            remoteRef.key = n.instance;
            remoteRef.property = "STGUIAPIKEY";
          }
          {
            secretKey = "caldav_password";
            remoteRef.key = davSecret;
            remoteRef.property = "password";
          }
        ];
      };
    };
  in {
    # org-bridge is a background reconciliation worker — no HTTP endpoint, no gatus check.
    # Health is observed indirectly via the CalDAV collection (baikal) and Syncthing events.
    applications = lib.mapAttrs' (user: table: lib.nameValuePair (nameOf user).bridge (bridge user table)) (lib.filterAttrs (_: t: t.folders ? org) syncthing.users);
  };
}
