# Trakt to Letterboxd (apps/letterboxd-sync, docs/scrobbling.md). Letterboxd has no write API, so a
# daily CronJob exports the films watched on Trakt since its last run as an import CSV, signs in to
# the owner's account with a headless Chromium and uploads it on letterboxd.com/import/. Automating
# that page may break Letterboxd's terms; the risks and the pace limits are in docs/scrobbling.md.
#
# Off by default: until `enable` is true (and the image is pinned) nothing renders, so there is no
# CronJob, no ExternalSecret and no PVC. docs/manual-steps.md 13 has the steps to turn it on.
{config, ...}: let
  letterboxd = {
    enable = false;
    # Public Trakt profile slug (Settings, Privacy), the same one Ryot imports from.
    traktUsername = "";
    # false: sign in and upload, then stop at the page's summary and tell ntfy what it says. The first
    # live runs use this; flip to true once the summary looks right.
    confirmImport = false;
    # First run only: import plays at or after this timestamp (e.g. "2026-01-01T00:00:00.000Z") as a
    # backfill. Empty records the current history as the baseline and imports only later plays.
    startAt = "";
    # After a run reports an unconfirmed batch: check the Letterboxd diary, then set "ack" (the films
    # are there) or "discard" (they are not), sync, and run the job once. Set it back to "" after.
    pendingAction = "";
  };
in {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    name = "letterboxd-sync";
    active = letterboxd.enable && pinned.images ? letterboxd-sync;
    # ntfy lives on hyena; pods don't resolve it (docs/observability.md).
    hostAliases = lib.toList {
      ip = "100.64.0.1";
      hostnames = ["ntfy.${domain}"];
    };
    env =
      {
        TRAKT_USERNAME = letterboxd.traktUsername;
        TRAKT_CLIENT_ID_FILE = "/secrets/trakt-client-id";
        LETTERBOXD_USERNAME_FILE = "/secrets/username";
        LETTERBOXD_PASSWORD_FILE = "/secrets/password";
        STATE_DIR = "/state";
        NTFY_URL = "https://ntfy.${domain}";
        NTFY_TOPIC = "media";
        # Never on the minute: a random start within half an hour, and 0.8 to 2.5 s between page actions.
        JITTER_SECS = "1800";
        PACE_MS_MIN = "800";
        PACE_MS_MAX = "2500";
        # More than this many new films go out over several nights, not in one upload.
        MAX_FILMS = "100";
      }
      // lib.optionalAttrs (!letterboxd.confirmImport) {STOP_BEFORE_CONFIRM = "1";}
      // lib.optionalAttrs (letterboxd.startAt != "") {START_AT = letterboxd.startAt;}
      // lib.optionalAttrs (letterboxd.pendingAction != "") {PENDING_ACTION = letterboxd.pendingAction;};
  in
    lib.mkIf active {
      applications.${name} = {
        namespace = "media";
        # The cursor and the "confirm clicked, outcome unknown" marker live here: losing them re-imports history.
        volsync.pvcs.${name} = {
          title = name;
          cacheAccessModes = ["ReadWriteOnce"];
        };
        resources.persistentVolumeClaims.${name} = {
          spec = {
            accessModes = ["ReadWriteOnce"];
            storageClassName = "ceph-block";
            resources.requests.storage = "1Gi";
          };
        };
        # letterboxd/* are the user's own Bitwarden items; the Trakt client id is the one Ryot's import uses.
        resources.externalSecrets.${name}.spec.data =
          map (item: {
            inherit (item) secretKey;
            remoteRef.key = item.key;
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }) [
            {
              secretKey = "username";
              key = "letterboxd/username";
            }
            {
              secretKey = "password";
              key = "letterboxd/password";
            }
            {
              secretKey = "trakt-client-id";
              key = "ryot/trakt/client-id";
            }
          ];
        resources.cronJobs.${name}.spec = {
          schedule = "17 3 * * *";
          timeZone = "America/Los_Angeles";
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            # No retry: a second login attempt right after a failed one is what gets accounts flagged.
            backoffLimit = 0;
            activeDeadlineSeconds = 3600;
            ttlSecondsAfterFinished = 86400;
            template = {
              metadata.labels."app.kubernetes.io/name" = name;
              spec = {
                restartPolicy = "Never";
                automountServiceAccountToken = false;
                inherit hostAliases;
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  fsGroup = 65534;
                  fsGroupChangePolicy = "OnRootMismatch";
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = lib.toList {
                  inherit name;
                  image = with pinned.images.letterboxd-sync; "${repository}:${tag}@${digest}";
                  env = lib.mapAttrsToList (name: value: {inherit name value;}) env;
                  resources = {
                    requests = {
                      cpu = "100m";
                      memory = "512Mi";
                    };
                    limits.memory = "1536Mi";
                  };
                  volumeMounts = [
                    {
                      name = "state";
                      mountPath = "/state";
                    }
                    {
                      name = "tmp";
                      mountPath = "/tmp";
                    }
                    {
                      name = "secrets";
                      mountPath = "/secrets";
                      readOnly = true;
                    }
                  ];
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = ["ALL"];
                  };
                };
                volumes = [
                  {
                    name = "state";
                    persistentVolumeClaim.claimName = name;
                  }
                  {
                    name = "tmp";
                    emptyDir = {};
                  }
                  {
                    name = "secrets";
                    secret.secretName = name;
                  }
                ];
              };
            };
          };
        };
      };
    };
}
