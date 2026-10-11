# Media-stack end-to-end tests (apps/media-e2e). A suspended CronJob holds the Job template;
# `media-e2e` in the devshell creates a Job from it, follows the log and saves the report.
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
    libs = ["movies" "tv" "music" "books" "audiobooks" "comics" "dvd" "downloads" "podcasts"];
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
      "dvd-webdav"
      "qbittorrent-admin"
    ];
  in {
    applications.${name} = lib.mkIf (pinned.images ? media-e2e) {
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
          suspend = true;
          schedule = "0 0 1 1 *";
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
                  # The media volumes are setgid root:101 or root:65534, group-writable.
                  supplementalGroups = [101];
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = lib.toList {
                  inherit name;
                  image = with pinned.images.media-e2e; "${repository}:${tag}@${digest}";
                  args = ["run"];
                  env = lib.mapAttrsToList (name: value: {inherit name value;}) {
                    DOMAIN = domain;
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
