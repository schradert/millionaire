# Tdarr: library health checks and (when enabled) HEVC transcoding on falcon's GPU.
#
# Safe by default, in three layers: the libraries are mounted read-only (nothing can replace an
# original), the libraries carry no transcode flow or plugin and have transcoding off, and the node
# gets one health-check worker and no transcode workers. Enabling transcoding is a deliberate edit:
# `writable = true`, then a transcode flow on the library and transcode workers on the node.
#
# Admin only: oauth2-proxy (Keycloak `admin` group) is the sign-in, Tdarr's own login is off, and
# the policy below keeps everything else off its ports.
{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "tdarr.${domain}";
    url = "http://tdarr.media.svc.cluster.local:8265";
    writable = false;
    nodeName = "falcon";
    libraries = {
      movies = "/media/movies";
      tv = "/media/tv";
    };
    # A library document as Tdarr's UI creates it, with transcoding off and no plugins.
    library = id: folder: {
      _id = id;
      name = lib.toUpper (lib.substring 0 1 id) + lib.substring 1 (-1) id;
      inherit folder;
      foldersToIgnore = "";
      foldersToIgnoreCaseInsensitive = false;
      folderWatchScanInterval = 30;
      scannerThreadCount = 1;
      cache = "";
      output = "";
      folderToFolderConversion = false;
      folderToFolderConversionDeleteSource = false;
      folderToFolderRecordHistory = true;
      copyIfConditionsMet = false;
      container = ".mkv";
      containerFilter = "mkv,mp4,mov,m4v,mpg,mpeg,avi,flv,webm,wmv,vob,evo,iso,m2ts,ts";
      createdAt = 1760000000000;
      # CephFS has no useful change events: an hourly scan finds new files.
      folderWatching = false;
      useFsEvents = false;
      scheduledScanFindNew = true;
      processLibrary = true;
      processTranscodes = false;
      processHealthChecks = true;
      scanOnStart = true;
      exifToolScan = true;
      mediaInfoScan = true;
      ffprobeShowData = false;
      isDirectoryLibrary = false;
      closedCaptionScan = false;
      scanButtons = true;
      scanFound = "";
      navItemSelected = "navSourceFolder";
      pluginIDs = [];
      pluginCommunity = true;
      handbrake = false;
      ffmpeg = true;
      handbrakescan = false;
      ffmpegscan = true;
      preset = "";
      decisionMaker = {
        settingsPlugin = true;
        settingsFlows = false;
        settingsVideo = false;
        videoExcludeSwitch = true;
        video_codec_names_exclude = [
          {
            codec = "hevc";
            checked = false;
          }
          {
            codec = "h264";
            checked = true;
          }
        ];
        video_size_range_include = {
          min = 0;
          max = 100000;
        };
        video_height_range_include = {
          min = 0;
          max = 3000;
        };
        video_width_range_include = {
          min = 0;
          max = 4000;
        };
        settingsAudio = false;
        audioExcludeSwitch = true;
        audio_codec_names_exclude = [
          {
            codec = "mp3";
            checked = true;
          }
          {
            codec = "aac";
            checked = false;
          }
        ];
        audio_size_range_include = {
          min = 0;
          max = 10;
        };
      };
      schedule = lib.concatMap (day:
        map (h: {
          _id = "${day}:${lib.fixedWidthNumber 2 h}-${lib.fixedWidthNumber 2 (lib.mod (h + 1) 24)}";
          checked = true;
        }) (lib.range 0 23)) ["Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"];
      priority = 0;
    };
    insert = collection: id: doc:
      builtins.toJSON {
        data = {
          inherit collection;
          mode = "insert";
          docID = id;
          obj = doc;
        };
      };
    # Idempotent, curlimages/curl busybox sh. A library is inserted only when missing (edits made
    # in the UI stay); the node's limits are set once (marked with a node tag) when it first shows
    # up, and a node that never shows up (falcon down) is not an error.
    bootstrap = ''
      set -eu
      S=${url}
      db() { curl -fsS -X POST $S/api/v2/cruddb -H 'Content-Type: application/json' -d "$1"; }
      i=0
      until curl -fsS $S/api/v2/status > /dev/null 2>&1; do
        i=$((i+1)); [ $i -lt 90 ] || { echo "tdarr did not come up" >&2; exit 1; }
        sleep 5
      done
      libs=$(db '{"data":{"collection":"LibrarySettingsJSONDB","mode":"getAll"}}')
      ${lib.concatStrings (lib.mapAttrsToList (id: folder: ''
          case "$libs" in
            *'"_id":"${id}"'*) echo "library ${id} exists" ;;
            *) db ${lib.escapeShellArg (insert "LibrarySettingsJSONDB" id (library id folder))} > /dev/null; echo "library ${id} added" ;;
          esac
        '')
        libraries)}
      i=0
      until nodes=$(db '{"data":{"collection":"NodeJSONDB","mode":"getAll"}}') && case "$nodes" in *'"_id":"${nodeName}"'*) true ;; *) false ;; esac; do
        i=$((i+1)); [ $i -lt 36 ] || { echo "node ${nodeName} not registered, limits left for the next sync"; exit 0; }
        sleep 5
      done
      case "$nodes" in
        *'bootstrapped'*) echo "node ${nodeName} already set up" ;;
        *)
          db '{"data":{"collection":"NodeJSONDB","mode":"update","docID":"${nodeName}","obj":{"nodeTags":"mapped,bootstrapped","workerLimits":{"healthcheckcpu":1,"healthcheckgpu":0,"transcodecpu":0,"transcodegpu":0}}}}' > /dev/null
          echo "node ${nodeName}: one health-check worker, no transcode workers" ;;
      esac
    '';
    mounts = lib.mapAttrs' (id: path:
      lib.nameValuePair "media-${id}" {
        type = "persistentVolumeClaim";
        existingClaim = "media-${id}";
        advancedMounts = lib.genAttrs ["tdarr" "tdarr-node"] (c: {
          ${c} = [
            {
              inherit path;
              readOnly = !writable;
            }
          ];
        });
      })
    libraries;
  in {
    portal.apps.tdarr = {
      groups = ["admin"];
      description = "Library health checks and transcoding";
    };
    gatus.endpoints.tdarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    oauth2Proxy.upstreams.${hostname} = {
      inherit url;
      namespace = "media";
      websocket = true;
    };
    applications.tdarr = {
      namespace = "media";
      volsync.pvcs.tdarr-server = {
        title = "tdarr-server";
        # Two movers ran restic init on the original path at once (two key files, one config), leaving a repository nobody can open.
        repositorySuffix = "--2";
      };
      volsync.pvcs.tdarr-configs.title = "tdarr-configs";
      helm.releases.tdarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.tdarr = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.tdarr = {
              image = pinned.images.tdarr;
              env = {
                TZ = "Etc/UTC";
                serverIP = "0.0.0.0";
                serverPort = "8266";
                webUIPort = "8265";
                internalNode = "false";
                inContainer = "true";
                auth = "false";
              };
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "512Mi";
                };
                limits.memory = "2Gi";
              };
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup = {
                enabled = true;
                spec.failureThreshold = 60;
              };
            };
          };
          # The node: falcon only (the one GPU), on the nvidia runtime without a device request, so
          # it shares the card with the desktop and dvdrip's encodes instead of holding it.
          controllers.tdarr-node = {
            annotations."reloader.stakater.com/auto" = "true";
            pod = {
              runtimeClassName = "nvidia";
              nodeSelector."nvidia.com/gpu.present" = "true";
              tolerations = lib.toList {
                key = "node.trdos.me/class";
                operator = "Equal";
                value = "desktop";
                effect = "PreferNoSchedule";
              };
            };
            containers.tdarr-node = {
              image = pinned.images.tdarr-node;
              env = {
                TZ = "Etc/UTC";
                serverIP = "tdarr.media.svc.cluster.local";
                serverPort = "8266";
                inherit nodeName;
                nodeType = "mapped";
                inContainer = "true";
                ffmpegVersion = "7";
                NVIDIA_VISIBLE_DEVICES = "all";
                NVIDIA_DRIVER_CAPABILITIES = "compute,video,utility";
              };
              # falcon is a workstation: a few cores at most and the smallest CPU weight, so the
              # desktop always wins.
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "512Mi";
                };
                limits = {
                  cpu = "4";
                  memory = "8Gi";
                };
              };
            };
          };
          service.tdarr = {
            controller = "tdarr";
            ports = {
              http.port = 8265;
              node.port = 8266;
            };
          };
          persistence =
            {
              server = {
                type = "persistentVolumeClaim";
                accessMode = "ReadWriteOnce";
                size = "5Gi";
                advancedMounts.tdarr.tdarr = [{path = "/app/server";}];
              };
              configs = {
                type = "persistentVolumeClaim";
                accessMode = "ReadWriteOnce";
                size = "1Gi";
                advancedMounts.tdarr.tdarr = [{path = "/app/configs";}];
              };
              logs = {
                type = "emptyDir";
                advancedMounts.tdarr.tdarr = [{path = "/app/logs";}];
              };
              node-logs = {
                type = "emptyDir";
                advancedMounts.tdarr-node.tdarr-node = [{path = "/app/logs";}];
              };
              node-configs = {
                type = "emptyDir";
                advancedMounts.tdarr-node.tdarr-node = [{path = "/app/configs";}];
              };
              # The node's scratch space on falcon's disk, never the libraries.
              transcode-cache = {
                type = "emptyDir";
                sizeLimit = "60Gi";
                advancedMounts.tdarr-node.tdarr-node = [{path = "/temp";}];
              };
            }
            // mounts;
          route.tdarr = {
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
        };
      };
      bootstrap = {
        image = with pinned.images.curl; "${repository}:${tag}@${digest}";
        args = ["sh" "-c" bootstrap];
      };
      # Login is off, so anyone who reaches the UI port is an admin: only oauth2-proxy, the e2e
      # Job and the bootstrap (UI/API), and the node (server port) may.
      resources.ciliumNetworkPolicies.tdarr.spec = {
        endpointSelector.matchLabels."app.kubernetes.io/name" = "tdarr";
        ingress = [
          {fromEntities = ["host"];}
          {
            fromEndpoints = [
              {
                matchLabels = {
                  "k8s:io.kubernetes.pod.namespace" = "identity";
                  "app.kubernetes.io/name" = "oauth2-proxy";
                };
              }
              {matchLabels."batch.kubernetes.io/job-name" = "tdarr-bootstrap";}
              {matchLabels."app.kubernetes.io/name" = "media-e2e";}
            ];
            toPorts = lib.toList {
              ports = lib.toList {
                port = "8265";
                protocol = "TCP";
              };
            };
          }
          {
            fromEndpoints = lib.toList {matchLabels."app.kubernetes.io/controller" = "tdarr-node";};
            toPorts = lib.toList {
              ports = lib.toList {
                port = "8266";
                protocol = "TCP";
              };
            };
          }
        ];
      };
    };
  };
}
