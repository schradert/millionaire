{...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    port = 5656;
    # Torrent downloads only: usenet clients unpack for themselves.
    arrs = {
      sonarr = "SONARR";
      radarr = "RADARR";
      lidarr = "LIDARR";
    };
    envName = app: field: "UN_${arrs.${app}}_0_${field}";
  in {
    # No UI and no hostname: nothing to route, tile or probe. `up` from the ServiceMonitor is its health.
    applications.unpackerr = {
      namespace = "media";
      helm.releases.unpackerr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.unpackerr = {
            annotations."reloader.stakater.com/auto" = "true";
            # The arr apps' uid, so it reads and writes /media/downloads as they and qBittorrent do.
            pod.securityContext = {
              runAsUser = 65534;
              runAsGroup = 65534;
              fsGroup = 65534;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.unpackerr = {
              image = pinned.images.unpackerr;
              envFrom = [{secretRef.name = "unpackerr";} {configMapRef.name = "unpackerr";}];
              resources.requests = {
                cpu = "10m";
                memory = "64Mi";
              };
              probes = lib.genAttrs ["liveness" "readiness"] (_: {
                enabled = true;
                custom = true;
                spec.tcpSocket.port = port;
              });
            };
          };
          service.unpackerr.ports.http.port = port;
          serviceMonitor.unpackerr = {
            serviceName = "unpackerr";
            endpoints = lib.toList {
              port = "http";
              path = "/metrics";
              interval = "1m";
            };
          };
          persistence = {
            tmpfs = {
              type = "emptyDir";
              globalMounts = lib.toList {
                path = "/tmp";
                subPath = "tmp";
              };
            };
            # Same path as qBittorrent and the arr apps, so the queue's paths need no mapping.
            media-downloads = {
              type = "persistentVolumeClaim";
              existingClaim = "media-downloads";
              advancedMounts.unpackerr.unpackerr = [{path = "/media/downloads";}];
            };
          };
          configMaps.unpackerr.data =
            {
              TZ = "Etc/UTC";
              UN_WEBSERVER_METRICS = "true";
              UN_WEBSERVER_LISTEN_ADDR = "0.0.0.0:${toString port}";
              UN_INTERVAL = "2m";
              UN_START_DELAY = "1m";
              UN_RETRY_DELAY = "5m";
              UN_MAX_RETRIES = "2";
              # Keep the archives: qBittorrent seeds them; the extracted copy goes after the import.
              UN_REMNANT_ACTION = "rename";
            }
            // lib.concatMapAttrs (app: _: {
              ${envName app "URL"} = "http://${app}.media.svc.cluster.local";
              ${envName app "PATHS_0"} = "/media/downloads";
              ${envName app "PROTOCOLS"} = "torrent";
              ${envName app "DELETE_DELAY"} = "5m";
              ${envName app "DELETE_ORIG"} = "false";
            })
            arrs;
        };
      };
      resources.externalSecrets.unpackerr.spec = {
        secretStoreRef.name = "kubernetes-media";
        secretStoreRef.kind = "ClusterSecretStore";
        data =
          lib.mapAttrsToList (app: _: {
            secretKey = envName app "API_KEY";
            remoteRef.key = "${app}-apikey";
            remoteRef.property = "apikey";
          })
          arrs;
      };
    };
  };
}
