{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "adguard.${domain}";
  adguardIP = "192.168.50.242";
in {
  nixidy = {charts, lib, ...}: {
    gatus.endpoints.adguard = {url = "https://${hostname}"; group = "internal";};
    applications.adguard = {
      namespace = "kube-system";
      helm.releases.adguard = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.adguard = {
            annotations."reloader.stakater.com/auto" = "true";
            initContainers.copy-config = {
              image.repository = "busybox";
              image.tag = "1.37";
              command = ["sh" "-c" ''
                if [ ! -f /opt/adguardhome/conf/AdGuardHome.yaml ]; then
                  cp /tmp/AdGuardHome.yaml /opt/adguardhome/conf/AdGuardHome.yaml
                fi
              ''];
            };
            containers.adguard = {
              image.repository = "adguard/adguardhome";
              image.tag = "v0.107.56";
              ports = [
                {name = "http"; containerPort = 3000;}
                {name = "dns-tcp"; containerPort = 53; protocol = "TCP";}
                {name = "dns-udp"; containerPort = 53; protocol = "UDP";}
              ];
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/";
                spec.httpGet.port = "http";
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/";
                spec.httpGet.port = "http";
              };
              probes.startup = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/";
                spec.httpGet.port = "http";
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };
          service.adguard = {
            primary = true;
            ports.http.port = 3000;
          };
          service.dns = {
            type = "LoadBalancer";
            annotations."lbipam.cilium.io/ips" = adguardIP;
            ports = {
              dns-tcp = {port = 53; protocol = "TCP";};
              dns-udp = {port = 53; protocol = "UDP";};
            };
          };
          persistence = {
            data = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "2Gi";
              advancedMounts.adguard = {
                copy-config = [{path = "/opt/adguardhome/conf"; subPath = "conf";}];
                adguard = [
                  {path = "/opt/adguardhome/conf"; subPath = "conf";}
                  {path = "/opt/adguardhome/work"; subPath = "work";}
                ];
              };
            };
            config = {
              type = "secret";
              name = "adguard-config";
              advancedMounts.adguard.copy-config = [
                {
                  path = "/tmp/AdGuardHome.yaml";
                  subPath = "AdGuardHome.yaml";
                  readOnly = true;
                }
              ];
            };
          };
        };
      };
      resources.externalSecrets.adguard-config.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        target.name = "adguard-config";
        target.template.data."AdGuardHome.yaml" = builtins.toJSON {
          http.address = "0.0.0.0:3000";
          dns = {
            bind_hosts = ["0.0.0.0"];
            port = 53;
            upstream_dns = [
              "[//]192.168.50.1" # bare hostnames → ASUS router
              "1.1.1.1"
              "1.0.0.1"
            ];
            bootstrap_dns = ["1.1.1.1" "1.0.0.1"];
          };
          filtering.rewrites = [
            {domain = "internal.${domain}"; answer = "192.168.50.241";}
          ];
          users = [
            {
              name = "admin";
              password = "{{ .password_hash }}";
            }
          ];
          schema_version = 29;
        };
        data = lib.toList {
          secretKey = "password_hash";
          remoteRef.key = "adguard/admin/password-hash";
        };
      };
      resources.httpRoutes.adguard.spec = {
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
      resources.rules.adguard.spec = {
        upstream.url = "http://adguard.kube-system.svc.cluster.local:3000";
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
}
