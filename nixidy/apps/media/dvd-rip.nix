# DVD ripping in the cluster (apps/dvdrip, docs/dvd-rip.md): a per-drive agent on every node
# labelled dvd.trdos.me/drive=true (NixOS writes the NFD feature, modules/dvd-rip.nix), a
# controller running the Disc phase machine, and the encode/publish Jobs it creates. The review
# view is at rips.<domain> behind oauth2-proxy.
{config, ...}: {
  nixidy = {
    lib,
    ntfyToken,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "rips.${domain}";
    ns = "media";
    published = pinned.images ? dvdrip;
    image = with pinned.images.dvdrip; "${repository}:${tag}@${digest}";
    labels = component: {
      "app.kubernetes.io/name" = "dvdrip";
      "app.kubernetes.io/component" = component;
    };
    # Discs imported from the bash pipeline without a good rip, to rip again when they are inserted
    # (fingerprints, the suffix of the Disc's name): 21 (the old MakeMKV had expired, its dvdbackup
    # copy is full of padded read errors) and NIGHTMARE (90 % rescued, the rest unreadable). Without
    # this the agent ejects them as duplicates of the import. A disc ripped for real is an ordinary
    # duplicate again, so entries can stay.
    rerip = ["78908b129df8" "c950f29a8fd5"];
    # Library names (and the disc number of a bonus disc) for discs waiting to be inserted, by
    # fingerprint (falcon's /data/dvd-rips/<LABEL>/.discid): a new Disc starts with these instead of
    # the label in title case ("Theillusionist D2"). Anything else is sorted with `kubectl patch`.
    presets = {
      "1e81002f26cd" = {
        name = "The Illusionist (2006)";
        disc = 2;
      };
      # Discs ripped again (rerip) take their preset too.
      "78908b129df8".name = "21 (2008)";
      f0c1551c027f.name = "Hitch (2005)";
      ac42f9693e7a.name = "The Martian Child (2007)";
      "13e61f2bb58e".name = "Vantage Point (2008)";
      "07c30a5ac85c".name = "Rendition (2007)";
    };
    # ddrescue's time budget for a scratched disc, per attempt (the default is 60 and 15 minutes):
    # a disc that hits it keeps its image and the read continues when it is reinserted.
    rescueMinutes = 180;
    trimMinutes = 30;
    # ntfy lives on hyena; pods don't resolve it (docs/observability.md).
    hostAliases = lib.toList {
      ip = "100.64.0.1";
      hostnames = ["ntfy.${domain}"];
    };
    common =
      [
        {
          name = "NTFY_URL";
          value = "https://ntfy.${domain}/dvd";
        }
        {
          name = "OTEL_EXPORTER_OTLP_ENDPOINT";
          value = "http://alloy.observability.svc.cluster.local:4318";
        }
      ]
      ++ ntfyToken.env "dvdrip";
    tmp = {
      volume = {
        name = "tmp";
        emptyDir = {};
      };
      mount = {
        name = "tmp";
        mountPath = "/tmp";
      };
    };
    work = readOnly: {
      volume = {
        name = "work";
        persistentVolumeClaim.claimName = "dvd-rip-work";
      };
      mount = {
        name = "work";
        mountPath = "/work";
        inherit readOnly;
      };
    };
    rule = apiGroups: resources: verbs: {inherit apiGroups resources verbs;};
    dvd = ["dvd.trdos.me"];
    binding = kind: name: {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        inherit kind name;
      };
      subjects = lib.toList {
        kind = "ServiceAccount";
        inherit name;
        namespace = ns;
      };
    };
    # Desktops carry a soft taint; the drive and the GPU are on one.
    desktop = {
      key = "node.trdos.me/class";
      operator = "Equal";
      value = "desktop";
      effect = "PreferNoSchedule";
    };
  in {
    applications.dvdrip-crds.namespace = ns;
    canivete.crds.dvdrip = {
      application = "dvdrip-crds";
      install = true;
      src = builtins.path {
        path = ../../../apps/dvdrip/crds;
        name = "dvdrip-crds";
      };
    };

    gatus.endpoints.dvdrip = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://dvdrip.${ns}.svc.cluster.local:9090";
      namespace = ns;
    };

    applications.dvdrip = {
      namespace = ns;
      ntfySecret = "publisher";
      resources = lib.mkMerge [
        {
          # Work dirs: masters until published, encodes, logs, review sheets. Re-creatable from
          # the ISOs in media-dvd, so not backed up.
          persistentVolumeClaims.dvd-rip-work = {
            spec = {
              accessModes = ["ReadWriteMany"];
              storageClassName = "ceph-filesystem";
              resources.requests.storage = "200Gi";
            };
          };

          serviceAccounts = {
            dvdrip-controller = {};
            dvdrip-agent = {};
            dvdrip-job = {};
          };
          roles = {
            dvdrip-controller.rules = [
              # patch: the finalizer that removes a deleted Disc's work dir.
              (rule dvd ["discs"] ["get" "list" "watch" "patch"])
              (rule dvd ["discs/status"] ["get" "patch" "update"])
              (rule ["batch"] ["jobs"] ["get" "list" "watch" "create" "delete"])
              (rule [""] ["pods"] ["get" "list"])
            ];
            dvdrip-agent.rules = [
              # patch: spec.hold=false on a disc ripped again on request (rerip).
              (rule dvd ["discs"] ["get" "list" "watch" "create" "patch"])
              (rule dvd ["discs/status"] ["get" "patch"])
            ];
            dvdrip-job.rules = [
              (rule dvd ["discs"] ["get"])
              (rule dvd ["discs/status"] ["get" "patch"])
            ];
          };
          roleBindings = {
            dvdrip-controller = binding "Role" "dvdrip-controller";
            dvdrip-agent = binding "Role" "dvdrip-agent";
            dvdrip-job = binding "Role" "dvdrip-job";
          };
          clusterRoles = {
            dvdrip-controller.rules = [
              (rule dvd ["drives"] ["get" "list" "watch"])
              (rule dvd ["drives/status"] ["get" "patch"])
            ];
            dvdrip-agent.rules = [
              (rule dvd ["drives"] ["get" "list" "watch" "create"])
              (rule dvd ["drives/status"] ["get" "patch"])
            ];
          };
          clusterRoleBindings = {
            dvdrip-controller = binding "ClusterRole" "dvdrip-controller";
            dvdrip-agent = binding "ClusterRole" "dvdrip-agent";
          };

          services.dvdrip.spec = {
            selector = labels "controller";
            ports = lib.toList {
              name = "http";
              port = 9090;
            };
          };
          podMonitors.dvdrip.spec = {
            selector.matchLabels."app.kubernetes.io/name" = "dvdrip";
            podMetricsEndpoints = lib.toList {
              port = "http";
              interval = "1m";
            };
          };
          prometheusRules.dvdrip = {
            metadata.labels.release = "prometheus";
            spec.groups = lib.toList {
              name = "dvdrip";
              rules = [
                {
                  alert = "DvdRipFailed";
                  expr = ''dvdrip_discs{name="Failed"} > 0'';
                  "for" = "10m";
                  labels.severity = "warning";
                  annotations.summary = "A disc failed to rip, encode or publish";
                  annotations.description = "kubectl -n media get discs; the Disc's status.message says why. Bump spec.retry to retry (docs/dvd-rip.md).";
                }
                {
                  alert = "DvdRipDriveError";
                  expr = ''dvdrip_drive_state{state="Error"} == 1'';
                  "for" = "15m";
                  labels.severity = "warning";
                  annotations.summary = "Optical drive {{ $labels.drive }} is in an error state";
                  annotations.description = "kubectl get drives; the agent's log on the drive's node.";
                }
              ];
            };
          };
        }
        (lib.mkIf published {
          deployments.dvdrip-controller.spec = {
            replicas = 1;
            strategy.type = "Recreate";
            selector.matchLabels = labels "controller";
            template = {
              metadata.labels = labels "controller";
              spec = {
                serviceAccountName = "dvdrip-controller";
                inherit hostAliases;
                # No desktop toleration: the headless nodes are the steadier home for it.
                containers = lib.toList {
                  name = "controller";
                  inherit image;
                  args = ["controller"];
                  env =
                    common
                    ++ [
                      {
                        name = "DVDRIP_IMAGE";
                        value = image;
                      }
                      {
                        name = "DVDRIP_JELLYFIN_URL";
                        value = "http://jellyfin.media.svc.cluster.local:8096";
                      }
                      # Files someone else put in the library, kept beside the rip (publish).
                      {
                        name = "NTFY_MEDIA_URL";
                        value = "https://ntfy.${domain}/media";
                      }
                      {
                        name = "OTEL_SERVICE_NAME";
                        value = "dvdrip-controller";
                      }
                    ];
                  ports = lib.toList {
                    name = "http";
                    containerPort = 9090;
                  };
                  readinessProbe.httpGet = {
                    path = "/healthz";
                    port = "http";
                  };
                  resources.requests = {
                    cpu = "20m";
                    memory = "64Mi";
                  };
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                  };
                  volumeMounts = [(work false).mount tmp.mount];
                };
                volumes = [(work false).volume tmp.volume];
              };
            };
          };

          daemonSets.dvdrip-agent.spec = {
            selector.matchLabels = labels "agent";
            template = {
              metadata.labels = labels "agent";
              spec = {
                serviceAccountName = "dvdrip-agent";
                nodeSelector."dvd.trdos.me/drive" = "true";
                inherit hostAliases;
                tolerations = [desktop];
                # A disc is read in one go; give an in-flight upload time to finish.
                terminationGracePeriodSeconds = 120;
                containers = lib.toList {
                  name = "agent";
                  inherit image;
                  args = ["agent"];
                  env =
                    common
                    ++ [
                      {
                        name = "NODE_NAME";
                        valueFrom.fieldRef.fieldPath = "spec.nodeName";
                      }
                      {
                        name = "DVDRIP_RESCUE_MINUTES";
                        value = toString rescueMinutes;
                      }
                      {
                        name = "DVDRIP_TRIM_MINUTES";
                        value = toString trimMinutes;
                      }
                      {
                        name = "DVDRIP_RERIP";
                        value = lib.concatStringsSep "," rerip;
                      }
                      {
                        name = "DVDRIP_PRESETS";
                        value = builtins.toJSON presets;
                      }
                      # The bash pipeline's rescue images (NIGHTMARE at 90 %, THEILLUSIONIST_D2) seed
                      # the staging of a disc that comes back, so its read continues from there.
                      {
                        name = "DVDRIP_SEED_DIR";
                        value = "/rips";
                      }
                      {
                        name = "OTEL_SERVICE_NAME";
                        value = "dvdrip-agent";
                      }
                    ];
                  ports = lib.toList {
                    name = "http";
                    containerPort = 9090;
                  };
                  resources.requests = {
                    cpu = "100m";
                    memory = "256Mi";
                  };
                  # The drive's block and SCSI-generic nodes (MakeMKV), ioctls for the tray.
                  securityContext.privileged = true;
                  volumeMounts = [
                    (work false).mount
                    tmp.mount
                    {
                      name = "staging";
                      mountPath = "/var/lib/dvd-rip";
                    }
                    {
                      name = "dev";
                      mountPath = "/dev";
                    }
                    {
                      name = "udev";
                      mountPath = "/run/udev";
                      readOnly = true;
                    }
                    {
                      name = "rips";
                      mountPath = "/rips";
                      readOnly = true;
                    }
                  ];
                };
                volumes = [
                  (work false).volume
                  tmp.volume
                  {
                    name = "staging";
                    hostPath = {
                      path = "/var/lib/dvd-rip";
                      type = "DirectoryOrCreate";
                    };
                  }
                  {
                    name = "dev";
                    hostPath.path = "/dev";
                  }
                  {
                    name = "udev";
                    hostPath.path = "/run/udev";
                  }
                  {
                    # falcon's bash-era rips; empty (created) on a node that never had them.
                    name = "rips";
                    hostPath = {
                      path = "/data/dvd-rips";
                      type = "DirectoryOrCreate";
                    };
                  }
                ];
              };
            };
          };

          # One-off, by hand (docs/dvd-rip.md): `kubectl -n media create job --from=cronjob/dvdrip-import dvdrip-import`.
          # Records the ISOs already in media-dvd as Done Discs (duplicate detection) and brings over the
          # bash pipeline's finished rips on falcon that never reached the cluster.
          cronJobs.dvdrip-import.spec = {
            suspend = true;
            schedule = "0 0 1 1 *";
            jobTemplate.spec = {
              backoffLimit = 0;
              ttlSecondsAfterFinished = 604800;
              template = {
                metadata.labels = labels "import";
                spec = {
                  restartPolicy = "Never";
                  serviceAccountName = "dvdrip-agent";
                  nodeSelector."kubernetes.io/hostname" = "falcon";
                  tolerations = [desktop];
                  containers = lib.toList {
                    name = "import";
                    inherit image;
                    resources.requests = {
                      cpu = "860m";
                      memory = "144Mi";
                    };
                    args = ["import" "--dvd-root" "/media/dvd" "--rips" "/rips"];
                    volumeMounts = [
                      (work false).mount
                      tmp.mount
                      {
                        name = "dvd";
                        mountPath = "/media/dvd";
                        readOnly = true;
                      }
                      {
                        name = "rips";
                        mountPath = "/rips";
                        readOnly = true;
                      }
                    ];
                  };
                  volumes = [
                    (work false).volume
                    tmp.volume
                    {
                      name = "dvd";
                      persistentVolumeClaim = {
                        claimName = "media-dvd";
                        readOnly = true;
                      };
                    }
                    {
                      name = "rips";
                      hostPath.path = "/data/dvd-rips";
                    }
                  ];
                };
              };
            };
          };

          httpRoutes.dvdrip.spec = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "oauth2-proxy";
                namespace = "identity";
                port = 4180;
              };
            };
          };
        })
      ];
    };
  };
}
