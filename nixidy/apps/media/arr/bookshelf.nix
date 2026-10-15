# Bookshelf (github.com/pennydreadful/bookshelf): the maintained revival of Readarr, which was
# archived in June 2025. The `hardcover` images read book metadata from rreading-glasses (a
# Hardcover-backed replacement for Readarr's dead metadata server), hosted upstream by default.
# One book type per instance, so two: `bookshelf` (ebooks -> media-books, read in Kavita) and
# `bookshelf-audio` (audiobooks -> media-audiobooks, in Audiobookshelf). Wired by the arr bootstrap
# (prowlarr.nix): root folders, qBittorrent (categories `bookshelf`, `bookshelf-audio`), Prowlarr's
# "Readarr" application sync and ntfy. It still speaks Readarr's API and READARR__* settings.
{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    port = 8787;
    instance = name: library: {
      portal.apps.${name}.groups = ["admin"];
      gatus.endpoints.${name} = {
        url = "https://${name}.${domain}";
        group = "internal";
        conditions = ["[STATUS] == any(200, 302, 401)"];
      };
      applications.${name} = {
        namespace = "media";
        volsync.pvcs.${name}.title = name;
        helm.releases.${name} = {
          chart = charts.bjw-s-labs.app-template-patched;
          values = {
            controllers.${name} = {
              annotations."reloader.stakater.com/auto" = "true";
              pod = {
                securityContext = {
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  fsGroup = 65534;
                  fsGroupChangePolicy = "OnRootMismatch";
                };
                # ntfy lives on hyena; pods don't resolve it (docs/observability.md).
                hostAliases = lib.toList {
                  ip = "100.64.0.1";
                  hostnames = ["ntfy.${domain}"];
                };
              };
              containers.exportarr = {
                image = pinned.images.exportarr;
                args = ["readarr"];
                env = {
                  PORT = "9707";
                  URL = "http://localhost:${toString port}";
                  APIKEY.valueFrom.secretKeyRef = {
                    inherit name;
                    key = "READARR__AUTH__APIKEY";
                  };
                };
                resources = {
                  requests = {
                    cpu = "5m";
                    memory = "32Mi";
                  };
                  limits.memory = "128Mi";
                };
              };
              containers.app = {
                image = pinned.images.bookshelf;
                # Straight to the binary, as the pod's non-root user: the image's s6 init wants root.
                command = ["/app/readarr/bin/Readarr"];
                args = ["-nobrowser" "-data=/config"];
                envFrom = [{secretRef.name = name;} {configMapRef.name = name;}];
                probes.liveness.enabled = true;
                probes.readiness.enabled = true;
                probes.startup.enabled = true;
                resources = {
                  requests = {
                    cpu = "20m";
                    memory = "192Mi";
                  };
                  limits.memory = "1Gi";
                };
              };
            };
            service.${name}.ports = {
              http.port = port;
              metrics.port = 9707;
            };
            serviceMonitor.${name} = {
              serviceName = name;
              endpoints = lib.toList {
                port = "metrics";
                path = "/metrics";
                interval = "1m";
              };
            };
            persistence = {
              # SQLite (no CNPG cluster: two small instances on saturated nodes); VolSync backs it up.
              config = {
                type = "persistentVolumeClaim";
                accessMode = "ReadWriteOnce";
                size = "1Gi";
                advancedMounts.${name}.app = [{path = "/config";}];
              };
              tmpfs = {
                type = "emptyDir";
                globalMounts = lib.toList {
                  path = "/tmp";
                  subPath = "tmp";
                };
              };
              ${library} = {
                type = "persistentVolumeClaim";
                existingClaim = library;
                advancedMounts.${name}.app = [{path = "/media/${lib.removePrefix "media-" library}";}];
              };
              media-downloads = {
                type = "persistentVolumeClaim";
                existingClaim = "media-downloads";
                advancedMounts.${name}.app = [{path = "/media/downloads";}];
              };
            };
            configMaps.${name}.data = {
              READARR__APP__INSTANCENAME = name;
              READARR__AUTH__METHOD = "External";
              READARR__AUTH__REQUIRED = "DisabledForLocalAddresses";
              READARR__LOG__DBENABLED = "False";
              READARR__LOG__LEVEL = "info";
              READARR__SERVER__PORT = toString port;
              READARR__SERVER__ALLOWEDHOSTS = lib.concatStringsSep "," ["${name}.${domain}" "${name}.media.svc.cluster.local" "${name}.media.svc" "${name}.media" name "localhost"];
            };
            route.${name} = {
              hostnames = ["${name}.${domain}"];
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
        # Random once, never refreshed: the app persists it as its own key.
        resources.passwords."${name}-apikey".spec = {
          length = 32;
          digits = 10;
          symbols = 0;
          noUpper = true;
          allowRepeat = true;
        };
        resources.externalSecrets."${name}-apikey".spec = {
          refreshPolicy = "CreatedOnce";
          dataFrom = lib.toList {
            sourceRef.generatorRef = {
              apiVersion = "generators.external-secrets.io/v1alpha1";
              kind = "Password";
              name = "${name}-apikey";
            };
            rewrite = lib.toList {
              regexp = {
                source = "password";
                target = "apikey";
              };
            };
          };
        };
        resources.externalSecrets.${name}.spec.data = lib.toList {
          secretKey = "READARR__AUTH__APIKEY";
          remoteRef.key = "${name}-apikey";
          remoteRef.property = "apikey";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
      };
      oauth2Proxy.upstreams."${name}.${domain}" = {
        url = "http://${name}.media.svc.cluster.local:${toString port}";
        namespace = "media";
      };
    };
  in
    lib.mkIf (pinned.images ? bookshelf) (lib.mkMerge [
      (instance "bookshelf" "media-books")
      (instance "bookshelf-audio" "media-audiobooks")
    ]);
}
