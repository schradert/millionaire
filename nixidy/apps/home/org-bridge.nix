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
      # Credentials generated in-cluster for syncthing and baikal.
      resources.externalSecrets.org-bridge.spec = {
        secretStoreRef.name = "kubernetes-home";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data = {
          SYNCTHING_API_KEY = "{{ .syncthing_key }}";
          CALDAV_USERNAME = "admin";
          CALDAV_PASSWORD = "{{ .caldav_password }}";
        };
        data = [
          {
            secretKey = "syncthing_key";
            remoteRef.key = "syncthing";
            remoteRef.property = "STGUIAPIKEY";
          }
          {
            secretKey = "caldav_password";
            remoteRef.key = "baikal";
            remoteRef.property = "BAIKAL_ADMIN_PASSWORD";
          }
        ];
      };
    };
  };
}
