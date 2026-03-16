{config, ...}: let
  bucketName = "${builtins.replaceStrings ["."] ["-"] config.canivete.meta.domain}--volsync";
in {
  nixidy = {
    can,
    lib,
    pkgs,
    ...
  }: {
    applications.volsync-crds.namespace = "kube-system";
    canivete.crds.volsync = {
      application = "volsync-crds";
      install = true;
      prefix = "config/crd/bases";
      src = pkgs.fetchFromGitHub {
        owner = "backube";
        repo = "volsync";
        rev = "v0.15.0";
        hash = "sha256-dq+xNKWWmWTJBuw7npxfl5U/ehrAb7OWmijEwGSvNPQ=";
      };
    };
    applications.volsync = {
      namespace = "storage";
      helm.releases.volsync = {
        chart = lib.helm.downloadHelmChart {
          chart = "volsync";
          version = "0.15.0";
          repo = "https://backube.github.io/helm-charts";
          chartHash = "sha256-MZxxd26S9wST2Jy7fFhriQX2T4n1gNKu2d+jtlPYpEs=";
        };
        values.manageCRDs = false;
      };
    };
    # Attaches VolSync replication mechanisms to target PVCs and back up to Backblaze B2
    nixidy.applicationImports = [
      ({config, name, ...}: {
        options.volsync = {
          enable = can.enable "Volsync replication of PVCs" {default = config.volsync.pvcs != null;};
          pvcs = can.attrs.submodule "Name of PVCs to replicate and back up" ({config, ...}: {
            options = {
              title = can.str "Name of PVC eventually created" {};
              path = can.list.str "Delimited location to inject dataSourceRef for ReplicationDestination" {
                default = ["persistentVolumeClaims" config.title];
              };
              uid = can.int "UID for podSecurityContext" {default = 101;};
              gid = can.int "GID for podSecurityContext" {default = 101;};
              inject = can.enable "Inject dataSourceRef into a PVC" {};
            };
          });
        };
        config = lib.mkIf config.volsync.enable {
          resources = lib.mkMerge (lib.flip lib.mapAttrsToList config.volsync.pvcs (pvcName: pvc: let
            inherit (pvc) title inject path uid gid;
            region = "us-west-004";
            repository = "volsync--${name}--${pvcName}";
          in
            lib.mkMerge [
              # Some services use operators that allow configuration injection into PersistentVolumeClaim templates
              # Some still don't offer ways to inject so we have to do this manually
              (lib.mkIf inject (lib.setAttrByPath path {
                spec.dataSourceRef = {
                  kind = "ReplicationDestination";
                  apiGroup = "volsync.backube";
                  name = "${repository}-dst";
                };
              }))
              {
                externalSecrets.${repository}.spec = {
                  secretStoreRef.name = "bitwarden";
                  secretStoreRef.kind = "ClusterSecretStore";
                  data = [
                    {
                      secretKey = "restic";
                      remoteRef.key = "volsync/restic/password";
                    }
                    {
                      secretKey = "id";
                      remoteRef.key = "backblaze/bucket/application_key_id";
                    }
                    {
                      secretKey = "password";
                      remoteRef.key = "backblaze/bucket/application_key";
                    }
                  ];
                  target.template.data = {
                    RESTIC_REPOSITORY = "s3:https://s3.${region}.backblazeb2.com/${bucketName}/${repository}";
                    RESTIC_PASSWORD = "{{ .restic }}";
                    AWS_ACCESS_KEY_ID = "{{ .id }}";
                    AWS_SECRET_ACCESS_KEY = "{{ .password }}";
                    AWS_DEFAULT_REGION = region;
                  };
                };
                # Copy every day at 4am, pruning every 8 days down to 1 per day/week/month/year
                replicationSources."${repository}-src".spec = {
                  sourcePVC = title;
                  trigger.schedule = "0 4 * * *";
                  restic = {
                    moverSecurityContext.fsGroup = gid;
                    copyMethod = "Direct";
                    pruneIntervalDays = 8;
                    inherit repository;
                    retain = {
                      daily = 1;
                      weekly = 1;
                      monthly = 1;
                      yearly = 1;
                    };
                  };
                };
                replicationDestinations."${repository}-dst".spec = {
                  # Override this to track restoration
                  trigger.manual = lib.mkDefault "1";
                  restic = {
                    moverSecurityContext.runAsGroup = gid;
                    moverSecurityContext.runAsUser = uid;
                    copyMethod = "Direct";
                    destinationPVC = title;
                    inherit repository;
                  };
                };
              }
            ]));
        };
      })
    ];
  };
}
