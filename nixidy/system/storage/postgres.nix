{config, ...}: let
  bucketName = "${builtins.replaceStrings ["."] ["-"] config.canivete.meta.domain}--volsync";
  region = "us-west-004";
in {
  nixidy = {
    can,
    charts,
    lib,
    pkgs,
    ...
  }: {
    applications.postgres-crds.namespace = "kube-system";
    canivete.crds.postgres = {
      application = "postgres-crds";
      install = true;
      prefix = "config/crd/bases";
      src = pkgs.fetchFromGitHub {
        owner = "cloudnative-pg";
        repo = "cloudnative-pg";
        rev = "v1.28.1";
        hash = "sha256-9NfjrVF0OtDLaGD5PPFSZcI8V3Vy/yOTm/JwnE3kMZE=";
      };
    };
    applications.postgres = {
      namespace = "storage";
      helm.releases.postgres = {
        chart = charts.cloudnative-pg.cloudnative-pg;
        values = {
          crds.create = false;
          monitoring = {
            grafanaDashboard.create = true;
            grafanaDashboard.namespace = "observability";
            podMonitorEnabled = true;
          };
        };
      };
    };

    nixidy.applicationImports = [
      ({
        config,
        name,
        ...
      }: let
        db = config.postgres;
        secretName = "${name}-b2-postgres";
      in {
        options.postgres = {
          enable = can.enable "CNPG PostgreSQL cluster" {};
          instances = can.int "Number of instances (primary + standbys)" {default = 1;};
          storageSize = can.str "PVC size per instance" {default = "5Gi";};
          storageClass = can.str "Storage class name" {default = "ceph-block";};
          version = can.str "PostgreSQL major version" {default = "17";};
          database = can.str "Database name" {default = name;};
          owner = can.str "Database owner" {default = name;};
          extensions = can.list.str "Extensions to CREATE EXTENSION" {default = [];};
          sharedPreloadLibraries = can.list.str "shared_preload_libraries" {default = [];};
          initSQL = can.list.str "Post-init SQL statements (superuser)" {default = [];};
          initApplicationSQL = can.list.str "Post-init SQL statements (app user)" {default = [];};
          pooler = {
            enable = can.enable "PgBouncer connection pooler" {};
            instances = can.int "Pooler replica count" {default = 1;};
            poolMode = can.enum ["session" "transaction"] "PgBouncer pool mode" {default = "transaction";};
          };
          monitoring = can.enable "Prometheus PodMonitor" {default = true;};
          backup = {
            schedule = can.str "Cron schedule for base backups" {default = "0 0 * * *";};
            retentionPolicy = can.str "Backup retention policy" {default = "30d";};
          };
        };

        config = lib.mkIf db.enable {
          resources = lib.mkMerge [
            {
              externalSecrets.${secretName}.spec = {
                secretStoreRef.name = "bitwarden";
                secretStoreRef.kind = "ClusterSecretStore";
                data = [
                  {
                    secretKey = "ACCESS_KEY_ID";
                    remoteRef.key = "backblaze/bucket/application_key_id";
                  }
                  {
                    secretKey = "ACCESS_SECRET_KEY";
                    remoteRef.key = "backblaze/bucket/application_key";
                  }
                ];
              };
              clusters.${name}.spec = {
                inherit (db) instances;
                imageName = "ghcr.io/cloudnative-pg/postgresql:${db.version}";
                serviceAccountTemplate.metadata.name = "${name}-pg";
                storage = {
                  inherit (db) storageClass;
                  size = db.storageSize;
                };
                bootstrap.initdb = {
                  database = db.database;
                  owner = db.owner;
                  postInitSQL =
                    (map (ext: "CREATE EXTENSION IF NOT EXISTS ${ext};") db.extensions)
                    ++ db.initSQL;
                  postInitApplicationSQL = db.initApplicationSQL;
                };
                backup = {
                  barmanObjectStore = {
                    destinationPath = "s3://${bucketName}/cnpg/${name}/";
                    endpointURL = "https://s3.${region}.backblazeb2.com";
                    s3Credentials = {
                      accessKeyId = {
                        name = secretName;
                        key = "ACCESS_KEY_ID";
                      };
                      secretAccessKey = {
                        name = secretName;
                        key = "ACCESS_SECRET_KEY";
                      };
                    };
                  };
                  retentionPolicy = db.backup.retentionPolicy;
                };
                monitoring.enablePodMonitor = db.monitoring;
                postgresql.shared_preload_libraries = db.sharedPreloadLibraries;
              };
              scheduledBackups.${name}.spec = {
                schedule = db.backup.schedule;
                backupOwnerReference = "self";
                cluster.name = name;
              };
            }
            (lib.mkIf db.pooler.enable {
              poolers.${name}.spec = {
                cluster.name = name;
                instances = db.pooler.instances;
                type = "rw";
                pgbouncer.poolMode = db.pooler.poolMode;
              };
            })
          ];
        };
      })
    ];
  };
}
