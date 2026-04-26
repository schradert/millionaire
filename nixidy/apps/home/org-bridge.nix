{...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    # State DB lives in an emptyDir — org files are the source of truth, so a restart
    # just triggers a full reconciliation against CalDAV, which is idempotent by design.
    # The DB file only appears once the worker finishes that initial reconciliation;
    # probe it to detect a wedged startup.
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.exec.command = ["sh" "-c" "test -f /var/lib/org-bridge/state.db"];
    };
  in {
    # org-bridge is a background reconciliation worker — no HTTP endpoint, no gatus check.
    # Health is observed indirectly via the CalDAV collection (baikal) and Syncthing events.
    applications.org-bridge = {
      namespace = "home";
      helm.releases.org-bridge = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.org-bridge = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.org-bridge = {
              image = {
                # TODO wire up ./modules/images.nix rust build once nix2container input is added
                repository = "ghcr.io/schradert/org-bridge";
                tag = "latest";
              };
              env = {
                ORG_DIR = "/org";
                STATE_DB_PATH = "/var/lib/org-bridge/state.db";
                SYNCTHING_URL = "http://syncthing.home.svc.cluster.local:8384";
                CALDAV_URL = "http://baikal.home.svc.cluster.local:80/dav.php/calendars/admin/org/";
                RUST_LOG = "info";
              };
              envFrom = [{secretRef.name = "org-bridge";}];
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
              existingClaim = "org-files";
              advancedMounts.org-bridge.org-bridge = [
                {
                  path = "/org";
                  readOnly = true;
                }
              ];
            };
            state = {
              type = "emptyDir";
              advancedMounts.org-bridge.org-bridge = [{path = "/var/lib/org-bridge";}];
            };
          };
        };
      };
      resources.externalSecrets.org-bridge.spec.data = map (e:
        e
        // {
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }) [
        {
          secretKey = "SYNCTHING_API_KEY";
          remoteRef.key = "syncthing/api-key";
        }
        {
          secretKey = "CALDAV_USERNAME";
          remoteRef.key = "baikal/admin-username";
        }
        {
          secretKey = "CALDAV_PASSWORD";
          remoteRef.key = "baikal/admin-password";
        }
      ];
    };
  };
}
