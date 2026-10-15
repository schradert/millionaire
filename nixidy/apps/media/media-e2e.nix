# Media family of the platform end-to-end tests (apps/e2e). The CronJob runs the offline
# suite nightly (03:45 UTC); `e2e run --family media` (alias `media-e2e`) in the devshell creates a Job from it,
# follows the log and saves the report. The latest report is also kept in the ConfigMap `media-e2e-last-report`. It lives in `media` because the family mounts the media
# volumes. The image is library/e2e once pinned, else the old library/media-e2e (same CLI).
# Test data lives only under `.e2e-<run>` folders and objects named `e2e-<run>`, and is removed
# (and checked gone) at the end of every run. See docs/manual-steps.md.
{config, ...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain people;
    name = "media-e2e";
    image = pinned.images.e2e or (pinned.images.media-e2e or null);
    libs = ["movies" "tv" "music" "books" "audiobooks" "comics" "dvd" "downloads" "podcasts" "games"];
    # Secret name -> mounted at /secrets/<name>.
    secrets = [
      "radarr-apikey"
      "sonarr-apikey"
      "lidarr-apikey"
      "prowlarr-apikey"
      "jellyfin-admin"
      "kavita-admin"
      "komga-admin"
      "audiobookshelf-admin"
      "navidrome-admin"
      "multi-scrobbler"
      "maloja-admin"
      "dvd-webdav"
      "qbittorrent-admin"
      "autobrr-admin"
      "ombi-apikey"
    ];
  in {
    applications.${name} = lib.mkIf (image != null) {
      namespace = "media";
      resources = {
        serviceAccounts.${name} = {};
        # exec into the qbittorrent pod (VPN leak tests); read recyclarr's CronJob status.
        roles.${name}.rules = [
          {
            apiGroups = [""];
            resources = ["pods"];
            verbs = ["get" "list"];
          }
          {
            apiGroups = [""];
            resources = ["pods/exec"];
            verbs = ["create"];
          }
          {
            apiGroups = ["batch"];
            resources = ["cronjobs"];
            verbs = ["get"];
          }
          # dvd-rip flow: a synth Pod (dvdrip image) registers a Disc; the flow watches, edits and
          # deletes it (apps/e2e/src/media/flows_dvdrip.rs).
          {
            apiGroups = [""];
            resources = ["pods"];
            verbs = ["create" "delete"];
          }
          {
            apiGroups = [""];
            resources = ["pods/log"];
            verbs = ["get"];
          }
          {
            apiGroups = ["dvd.trdos.me"];
            resources = ["discs"];
            verbs = ["get" "list" "patch" "delete"];
          }
          # The latest report is kept in one ConfigMap (`kubectl apply`: get, patch, create).
          {
            apiGroups = [""];
            resources = ["configmaps"];
            verbs = ["create"];
          }
          {
            apiGroups = [""];
            resources = ["configmaps"];
            resourceNames = ["${name}-last-report"];
            verbs = ["get" "update" "patch"];
          }
        ];
        roleBindings.${name} = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            inherit name;
          };
          subjects = lib.toList {
            kind = "ServiceAccount";
            inherit name;
            namespace = "media";
          };
        };
        cronJobs.${name}.spec = {
          # The offline suite nightly after the cluster runner's (`--full`, the VPN tests, stays manual).
          schedule = "45 3 * * *";
          timeZone = "Etc/UTC";
          concurrencyPolicy = "Forbid";
          startingDeadlineSeconds = 3600;
          successfulJobsHistoryLimit = 3;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            backoffLimit = 0;
            activeDeadlineSeconds = 10800;
            ttlSecondsAfterFinished = 86400;
            template = {
              metadata.labels."app.kubernetes.io/name" = name;
              spec = {
                restartPolicy = "Never";
                serviceAccountName = name;
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  # The media volumes are setgid root:101 or root:65534, group-writable. books, audiobooks,
                  # comics, dvd and podcasts are still root:101 (the old VolSync mover chown), so 101 stays.
                  supplementalGroups = [101];
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = lib.toList {
                  inherit name;
                  image = with image; "${repository}:${tag}@${digest}";
                  args = ["run" "--family" "media"];
                  env = lib.mapAttrsToList (name: value: {inherit name value;}) {
                    E2E_RUNNER = "media";
                    DVDRIP_IMAGE = lib.optionalString (pinned.images ? dvdrip) (with pinned.images.dvdrip; "${repository}:${tag}@${digest}");
                    OTEL_EXPORTER_OTLP_ENDPOINT = "http://alloy.observability.svc.cluster.local:4318";
                    # CPU profiles (apps/e2e/src/profile.rs, e2e >= 0.7), tagged family/flow/phase.
                    PYROSCOPE_SERVER_ADDRESS = "http://pyroscope.observability.svc.cluster.local:4040";
                    # A short run burns little CPU: 1 kHz (CPU-time sampling, free while idle) gives it samples.
                    PYROSCOPE_SAMPLE_RATE = "1000";
                    E2E_REPORT_CONFIGMAP = "media/${name}-last-report";
                    DOMAIN = domain;
                    AUTOBRR_USER = people.me;
                    ADMIN_EMAIL = people.my.profiles.personal.email;
                  };
                  resources = {
                    requests = {
                      cpu = "50m";
                      memory = "64Mi";
                    };
                    limits.memory = "512Mi";
                  };
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = ["ALL"];
                  };
                  volumeMounts =
                    [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                    ]
                    ++ map (l: {
                      name = "media-${l}";
                      mountPath = "/media/${l}";
                    })
                    libs
                    ++ map (s: {
                      name = s;
                      mountPath = "/secrets/${s}";
                      readOnly = true;
                    })
                    secrets;
                };
                volumes =
                  [
                    {
                      name = "tmp";
                      emptyDir = {};
                    }
                  ]
                  ++ map (l: {
                    name = "media-${l}";
                    persistentVolumeClaim.claimName = "media-${l}";
                  })
                  libs
                  ++ map (s: {
                    name = s;
                    secret = {
                      secretName = s;
                      optional = true;
                    };
                  })
                  secrets;
              };
            };
          };
        };
      };
    };
  };
}
