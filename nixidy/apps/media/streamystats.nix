{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    webPort = 3000;
    jobPort = 3005;
    nobody = 65534;
    postgresImage = with pinned.images.immich-postgres; "${repository}:${tag}@${digest}";
    probe = path: port: {
      enabled = true;
      custom = true;
      spec.httpGet = {inherit path port;};
    };
    fromMediaStore = secretKey: key: property: {
      inherit secretKey;
      remoteRef = {inherit key property;};
      sourceRef.storeRef.name = "kubernetes-media";
      sourceRef.storeRef.kind = "ClusterSecretStore";
    };
  in {
    # In cluster only, deliberately no route, portal entry or oauth2-proxy upstream: Streamystats signs
    # people in with a Jellyfin username and password, which Jellyfin SSO users do not have, and it
    # keeps no per-user session a proxy could mint (the session is a cookie signed with SESSION_SECRET
    # plus the user's Jellyfin token). Putting it behind the gateway would leave only the shared Jellyfin
    # admin login, which breaks the per-user rule. So nothing human-facing exists yet; it serves
    # Maintainerr (item details and watchlists through its API, with the Jellyfin API key Maintainerr
    # already has) and ingests the statistics from Jellyfin. Human access waits for a per-user path: a
    # sidecar behind oauth2-proxy (like seerr-sso) that gets the user's Jellyfin token without a
    # password and mints Streamystats' session (docs/media-stack.md).
    applications.streamystats = {
      namespace = "media";
      # Its API and web UI run without a login of their own for anything that reaches them, so only
      # the Streamystats pods themselves (web, job server), Maintainerr, the Streamystats bootstrap Job,
      # the e2e Job and the kubelet may.
      resources.ciliumNetworkPolicies.streamystats.spec = {
        endpointSelector.matchLabels."app.kubernetes.io/instance" = "streamystats";
        ingress = [
          {fromEntities = ["host"];}
          {
            fromEndpoints = [
              {matchLabels."app.kubernetes.io/instance" = "streamystats";}
              {matchLabels."app.kubernetes.io/name" = "maintainerr";}
              {matchLabels."batch.kubernetes.io/job-name" = "maintainerr-bootstrap";}
              {matchLabels."batch.kubernetes.io/job-name" = "streamystats-bootstrap";}
              {matchLabels."app.kubernetes.io/name" = "media-e2e";}
            ];
            toPorts = [
              {
                ports = [
                  {
                    port = toString webPort;
                    protocol = "TCP";
                  }
                  {
                    port = toString jobPort;
                    protocol = "TCP";
                  }
                ];
              }
            ];
          }
        ];
      };
      # pgvector for the optional embeddings; the stock CNPG operand image has none, so the same
      # image as immich (VectorChord, which brings `vector`). uuid-ossp and pg_trgm are contrib.
      postgres = {
        enable = true;
        image = postgresImage;
        uid = 999;
        gid = 999;
        extensions = ["vector" "uuid-ossp" "pg_trgm"];
        # That image has no barman-cloud tools (see immich), so the Barman Cloud plugin archives from a
        # sidecar. The dump CronJob below stays as a second, logical copy.
        backup.method = "plugin";
      };
      # Idempotent post-sync bootstrap (apps/app-bootstrap streamystats, >= 0.24.0): a Jellyfin API key
      # named Streamystats (signed in as the Jellyfin admin) and the Jellyfin server in Streamystats.
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-streamystats) {
        image = with pinned.images.app-bootstrap-streamystats; "${repository}:${tag}@${digest}";
        args = ["streamystats"];
        env = {
          JELLYFIN_ADMIN_PASSWORD_FILE = "/secrets/jellyfin/password";
          JELLYFIN_PUBLIC_URL = "https://jellyfin.${domain}";
        };
        secrets.jellyfin = "jellyfin-admin";
      };
      generatedSecrets = {
        streamystats-session = {
          key = "secret";
          length = 64;
        };
        streamystats-internal = {
          key = "secret";
          length = 64;
        };
        # Next.js server-action key: base64 of 16/24/32 bytes, so 32 characters.
        streamystats-actions = {
          key = "secret";
          length = 32;
          numeric = true;
        };
      };
      resources.externalSecrets.streamystats.spec = {
        data = [
          (fromMediaStore "db" "streamystats-app" "password")
          (fromMediaStore "session" "streamystats-session" "secret")
          (fromMediaStore "internal" "streamystats-internal" "secret")
          (fromMediaStore "actions" "streamystats-actions" "secret")
        ];
        target.template.data = {
          DATABASE_URL = "postgresql://streamystats:{{ .db }}@streamystats-rw.media.svc.cluster.local:5432/streamystats";
          SESSION_SECRET = "{{ .session }}";
          INTERNAL_API_KEY = "{{ .internal }}";
          NEXT_SERVER_ACTIONS_ENCRYPTION_KEY = "{{ .actions }}";
        };
      };
      helm.releases.streamystats = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          # Web UI: users sign in with their own Jellyfin account, and see their own statistics
          # (Jellyfin admins also manage the server). The job server syncs Jellyfin into Postgres.
          controllers.streamystats = {
            annotations."reloader.stakater.com/auto" = "true";
            pod.securityContext = {
              runAsUser = nobody;
              runAsGroup = nobody;
            };
            containers.streamystats = {
              image = pinned.images.streamystats-nextjs;
              resources.requests = {
                cpu = "25m";
                memory = "112Mi";
              };
              envFrom = [{secretRef.name = "streamystats";} {configMapRef.name = "streamystats";}];
              probes = {
                liveness = probe "/api/health" webPort;
                readiness = probe "/api/health" webPort;
                startup = lib.recursiveUpdate (probe "/api/health" webPort) {spec.failureThreshold = 60;};
              };
            };
          };
          # Runs the migrations before it starts, so the web UI's startup probe waits for it.
          controllers.job-server = {
            annotations."reloader.stakater.com/auto" = "true";
            pod.securityContext = {
              runAsUser = nobody;
              runAsGroup = nobody;
            };
            containers.streamystats-job-server = {
              image = pinned.images.streamystats-job-server;
              envFrom = [{secretRef.name = "streamystats";} {configMapRef.name = "streamystats-job-server";}];
              probes = {
                liveness = probe "/health/live" jobPort;
                readiness = probe "/health/live" jobPort;
                startup = lib.recursiveUpdate (probe "/health/live" jobPort) {spec.failureThreshold = 120;};
              };
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "256Mi";
                };
                limits.memory = "2Gi";
              };
            };
          };
          service.streamystats = {
            controller = "streamystats";
            ports.http.port = webPort;
          };
          service.job-server = {
            controller = "job-server";
            ports.http.port = jobPort;
          };
          persistence.tmpfs = {
            type = "emptyDir";
            advancedMounts.streamystats.streamystats = [
              {
                path = "/tmp";
                subPath = "tmp";
              }
              {
                # Next's image and data caches.
                path = "/app/apps/nextjs-app/.next/cache";
                subPath = "next-cache";
              }
            ];
          };
          configMaps.streamystats.data = {
            NODE_ENV = "production";
            HOSTNAME = "0.0.0.0";
            PORT = toString webPort;
            NEXT_TELEMETRY_DISABLED = "1";
            JOB_SERVER_URL = "http://streamystats-job-server.media.svc.cluster.local:${toString jobPort}";
          };
          configMaps.job-server.data = {
            NODE_ENV = "production";
            HOST = "0.0.0.0";
            PORT = toString jobPort;
            NEXTJS_URL = "http://streamystats.media.svc.cluster.local:${toString webPort}";
          };
        };
      };
      # Nightly dump, kept for a week, on a volume VolSync backs up.
      volsync.pvcs.streamystats-dump.title = "streamystats-dump";
      resources.persistentVolumeClaims.streamystats-dump.spec = {
        accessModes = ["ReadWriteOnce"];
        storageClassName = "ceph-block";
        resources.requests.storage = "5Gi";
      };
      resources.cronJobs.streamystats-dump.spec = {
        schedule = "30 3 * * *";
        concurrencyPolicy = "Forbid";
        successfulJobsHistoryLimit = 1;
        failedJobsHistoryLimit = 2;
        jobTemplate.spec = {
          backoffLimit = 2;
          template.spec = {
            restartPolicy = "OnFailure";
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 999;
              runAsGroup = 999;
              fsGroup = 999;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = lib.toList {
              name = "dump";
              image = postgresImage;
              resources.requests = {
                cpu = "25m";
                memory = "32Mi";
              };
              command = ["bash" "-c"];
              args = [
                ''
                  set -eu
                  f=/dump/streamystats-$(date +%a).dump
                  pg_dump --format=custom --no-owner --file="$f.tmp" && mv "$f.tmp" "$f"
                ''
              ];
              env = [
                {
                  name = "PGHOST";
                  value = "streamystats-rw.media.svc.cluster.local";
                }
                {
                  name = "PGUSER";
                  value = "streamystats";
                }
                {
                  name = "PGDATABASE";
                  value = "streamystats";
                }
                {
                  name = "PGSSLMODE";
                  value = "disable";
                }
                {
                  name = "PGPASSWORD";
                  valueFrom.secretKeyRef = {
                    name = "streamystats-app";
                    key = "password";
                  };
                }
              ];
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = ["ALL"];
              };
              volumeMounts = [
                {
                  name = "dump";
                  mountPath = "/dump";
                }
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
              ];
            };
            volumes = [
              {
                name = "dump";
                persistentVolumeClaim.claimName = "streamystats-dump";
              }
              {
                name = "tmp";
                emptyDir = {};
              }
            ];
          };
        };
      };
    };
  };
}
