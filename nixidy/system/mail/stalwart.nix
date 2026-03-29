{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "mail.${domain}";
  ports.smtp = 25;
  ports.http = 8080;
in {
  nixidy = {
    charts,
    lib,
    pkgs,
    ...
  }: {
    gatus.endpoints.stalwart = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == 401"];
    };
    applications.stalwart = {
      namespace = "mail";
      volsync.pvcs.stalwart.title = "stalwart";
      helm.releases.stalwart = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.stalwart = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.stalwart = {
              image = {
                repository = "stalwartlabs/stalwart";
                tag = "v0.15.5";
                digest = "sha256:b6c2a04a79695136d5e2c16e9da0254135d0c3f3b1f8147873e812916b0ae8c4";
              };
              envFrom = [{secretRef.name = "stalwart";}];
              ports = [
                {
                  name = "smtp";
                  containerPort = ports.smtp;
                }
                {
                  name = "http";
                  containerPort = ports.http;
                }
              ];
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/healthz/live";
                spec.httpGet.port = "http";
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/healthz/ready";
                spec.httpGet.port = "http";
              };
              probes.startup = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/healthz/live";
                spec.httpGet.port = "http";
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };
          service.stalwart.ports = {
            smtp.port = ports.smtp;
            http.port = ports.http;
          };
          serviceMonitor.stalwart.endpoints = lib.toList {
            port = "http";
            path = "/metrics/prometheus";
          };
          persistence = {
            data = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "2Gi";
              advancedMounts.stalwart.stalwart = [{path = "/data";}];
            };
            config = {
              type = "configMap";
              name = "stalwart";
              advancedMounts.stalwart.stalwart = [
                {
                  path = "/opt/stalwart/etc/config.toml";
                  subPath = "config.toml";
                  readOnly = true;
                }
              ];
            };
          };
          configMaps.stalwart.data."config.toml" = builtins.readFile ((pkgs.formats.toml {}).generate "stalwart.toml" {
            # Keys matching these patterns are authoritative from TOML, not overridden by RocksDB defaults
            config.local-keys = [
              "store.*"
              "storage.*"
              "server.*"
              "directory.*"
              "authentication.fallback-admin.*"
              "tracer.*"
              "metrics.prometheus.*"
              "session.*"
              "queue.*"
              "config.local-keys.*"
            ];

            server.listener = {
              smtp = {
                protocol = "smtp";
                bind = ["[::]:${toString ports.smtp}"];
              };
              management = {
                protocol = "http";
                bind = ["[::]:${toString ports.http}"];
              };
            };

            store.rocksdb = {
              type = "rocksdb";
              path = "/data";
              compression = "lz4";
            };
            directory.internal = {
              type = "internal";
              store = "rocksdb";
            };
            storage = {
              data = "rocksdb";
              fts = "rocksdb";
              blob = "rocksdb";
              lookup = "rocksdb";
              directory = "internal";
            };

            tracer.stdout = {
              enable = true;
              type = "stdout";
              level = "info";
              ansi = false;
            };
            authentication.fallback-admin = {
              user = "admin";
              secret = "%{env:ADMIN_SECRET}%";
            };
            metrics.prometheus.enable = true;
            session.rcpt.relay = true;

            queue.strategy.route = "'relay'";
            queue.route.relay = {
              type = "relay";
              address = "smtp.protonmail.ch";
              port = 587;
              protocol = "smtp";
              tls.implicit = false;
              tls.allow-invalid-certs = false;
              auth.username = "noreply@${domain}";
              auth.secret = "%{env:SMTP_TOKEN}%";
            };
            # Trailing newline required to avoid Stalwart "Unexpected EOF" parse error.
          }) + "\n";
        };
      };
      resources = {
        externalSecrets.stalwart.spec.data = [
          {
            secretKey = "SMTP_TOKEN";
            remoteRef.key = "stalwart/smtp/token";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "ADMIN_SECRET";
            remoteRef.key = "stalwart/admin/password";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
        httpRoutes.stalwart.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "oathkeeper-proxy";
              namespace = "identity";
              port = 4455;
            };
          };
        };
        rules.stalwart.spec = {
          upstream.url = "http://stalwart.mail.svc.cluster.local:8080";
          match = {
            url = "https://${hostname}/<.*>";
            methods = ["GET" "POST" "PUT" "PATCH" "DELETE"];
          };
          authenticators = lib.toList {handler = "cookie_session";};
          authorizer.handler = "allow";
          mutators = lib.toList {handler = "header";};
          errors = lib.toList {handler = "redirect";};
        };
      };
    };
  };
}
