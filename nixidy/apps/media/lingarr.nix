{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "lingarr.${domain}";
    port = 9876;
    # Languages Lingarr translates from and to. LibreTranslate loads only these models. The targets are
    # the language-practice set of Bazarr (nixidy/apps/media/arr/bazarr.nix): Lingarr only translates a
    # language the media has no subtitle file for, so what Bazarr finds is never overwritten.
    languages = {
      en = "English";
      pt = "Portuguese";
      es = "Spanish";
      fr = "French";
      de = "German";
    };
    language = code: {
      name = languages.${code};
      inherit code;
    };
    source = ["en"];
    target = ["pt" "es" "fr" "de"];
    # Bifrost (nixidy/system/ai) as the primary translator, LibreTranslate the fallback. Off until the
    # gateway has provider keys (`providerKeys` in bifrost.nix); with it on and no keys, every request
    # fails and Lingarr falls through to LibreTranslate.
    bifrost = {
      enable = false;
      model = "anthropic/claude-haiku-4-5";
    };
    libretranslate = "http://libretranslate.media.svc.cluster.local:5000";
    arrs = {
      sonarr = "SONARR";
      radarr = "RADARR";
    };
  in {
    portal.apps.lingarr = {
      groups = ["admin"];
      icon = "mdi-subtitles";
      description = "Subtitle translation for Sonarr and Radarr media";
    };
    gatus.endpoints.lingarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.lingarr = {
      namespace = "media";
      volsync.pvcs.lingarr.title = "lingarr";
      # Idempotent post-sync bootstrap (apps/app-bootstrap lingarr): completes the first-run
      # onboarding (no app login: oauth2-proxy is the gate) and turns the scheduled library
      # translation on, a few files a run. Everything else is the environment below.
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-lingarr) {
        image = with pinned.images.app-bootstrap-lingarr; "${repository}:${tag}@${digest}";
        args = ["lingarr"];
        env.LINGARR_URL = "http://lingarr.media.svc.cluster.local:${toString port}";
      };
      helm.releases.lingarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.lingarr = {
            annotations."reloader.stakater.com/auto" = "true";
            # The arr apps' uid, so the subtitles it writes beside the media belong to the same owner.
            pod.securityContext = {
              runAsUser = 65534;
              runAsGroup = 65534;
              fsGroup = 65534;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.lingarr = {
              image = pinned.images.lingarr;
              envFrom = [{secretRef.name = "lingarr";} {configMapRef.name = "lingarr";}];
              resources.requests = {
                cpu = "20m";
                memory = "192Mi";
              };
              probes =
                lib.genAttrs ["liveness" "readiness"] (_: {
                  enabled = true;
                  custom = true;
                  spec.tcpSocket.port = port;
                })
                // {
                  startup = {
                    enabled = true;
                    custom = true;
                    spec = {
                      tcpSocket.port = port;
                      failureThreshold = 60;
                    };
                  };
                };
            };
          };
          service.lingarr.ports.http.port = port;
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
              globalMounts = [{path = "/app/config";}];
            };
            tmpfs = {
              type = "emptyDir";
              globalMounts = lib.toList {
                path = "/tmp";
                subPath = "tmp";
              };
            };
            # Writable: the translated subtitle lands next to its video. The same paths the arr apps
            # report, so Lingarr needs no path mapping.
            media-movies = {
              type = "persistentVolumeClaim";
              existingClaim = "media-movies";
              advancedMounts.lingarr.lingarr = [{path = "/media/movies";}];
            };
            media-tv = {
              type = "persistentVolumeClaim";
              existingClaim = "media-tv";
              advancedMounts.lingarr.lingarr = [{path = "/media/tv";}];
            };
          };
          # Every value here is applied to Lingarr's settings on each start (StartupService).
          configMaps.lingarr.data =
            {
              ASPNETCORE_URLS = "http://+:${toString port}";
              TZ = "Etc/UTC";
              DB_CONNECTION = "sqlite";
              MAX_CONCURRENT_JOBS = "1";
              TELEMETRY_ENABLED = "false";
              # oauth2-proxy (admin group) is the gate.
              AUTH_ENABLED = "false";
              SOURCE_LANGUAGES = builtins.toJSON (map language source);
              TARGET_LANGUAGES = builtins.toJSON (map language target);
              SERVICE_TYPE = builtins.toJSON (lib.optional bifrost.enable "localai" ++ ["libretranslate"]);
              LIBRE_TRANSLATE_URL = libretranslate;
            }
            // lib.optionalAttrs bifrost.enable {
              LOCAL_AI_ENDPOINT = "http://bifrost.ai.svc.cluster.local:8000/v1/chat/completions";
              LOCAL_AI_MODEL = bifrost.model;
              # Bifrost does not check it; the field must not be empty.
              LOCAL_AI_API_KEY = "bifrost";
            }
            // lib.concatMapAttrs (app: env: {
              "${env}_URL" = "http://${app}.media.svc.cluster.local";
            })
            arrs;
          route.lingarr = {
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
      resources.externalSecrets.lingarr.spec = {
        secretStoreRef.name = "kubernetes-media";
        secretStoreRef.kind = "ClusterSecretStore";
        data =
          lib.mapAttrsToList (app: env: {
            secretKey = "${env}_API_KEY";
            remoteRef.key = "${app}-apikey";
            remoteRef.property = "apikey";
          })
          arrs;
      };
    };
    # Self-hosted machine translation: nothing leaves the cluster. The models (a few hundred MB per
    # language pair) download on first start into the volume.
    applications.libretranslate = {
      namespace = "media";
      deletable = ["libretranslate"];
      helm.releases.libretranslate = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.libretranslate = {
            # The image runs as libretranslate (1032); the volume mounts root-owned.
            pod.securityContext = {
              runAsUser = 1032;
              runAsGroup = 1032;
              fsGroup = 1032;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.libretranslate = {
              image = pinned.images.libretranslate;
              env = {
                LT_LOAD_ONLY = lib.concatStringsSep "," (lib.unique (source ++ target));
                LT_DISABLE_WEB_UI = "true";
                # LibreTranslate only installs models at start when fewer than two are installed, so
                # adding a language to LT_LOAD_ONLY needs this: it downloads the missing models of
                # the loaded languages and updates one only when a newer version exists.
                LT_UPDATE_MODELS = "true";
              };
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "1Gi";
                };
                # Eight models (en to and from four languages), about 200 MB of model data per pair.
                limits.memory = "4Gi";
              };
              probes = {
                liveness = {
                  enabled = true;
                  custom = true;
                  spec = {
                    httpGet = {
                      path = "/languages";
                      port = 5000;
                    };
                    periodSeconds = 30;
                    timeoutSeconds = 10;
                  };
                };
                readiness = {
                  enabled = true;
                  custom = true;
                  spec.httpGet = {
                    path = "/languages";
                    port = 5000;
                  };
                };
                # The first start downloads the models.
                startup = {
                  enabled = true;
                  custom = true;
                  spec = {
                    httpGet = {
                      path = "/languages";
                      port = 5000;
                    };
                    periodSeconds = 10;
                    failureThreshold = 90;
                  };
                };
              };
            };
          };
          service.libretranslate.ports.http.port = 5000;
          persistence = {
            models = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "3Gi";
              globalMounts = [{path = "/home/libretranslate/.local";}];
            };
            # API-key database; no keys are used, it only has to be writable.
            db = {
              type = "emptyDir";
              globalMounts = [{path = "/app/db";}];
            };
            tmpfs = {
              type = "emptyDir";
              globalMounts = lib.toList {
                path = "/tmp";
                subPath = "tmp";
              };
            };
          };
        };
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://lingarr.media.svc.cluster.local:${toString port}";
      namespace = "media";
    };
  };
}
