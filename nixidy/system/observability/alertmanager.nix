{config, ...}: {
  nixidy = {lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "alertmanager.${domain}";
    # hyena's ntfy + Gatus (static/hyena.nix): tailnet-only https vhosts with
    # real certs. The names have no public DNS and CoreDNS can't see AdGuard,
    # so hostAliases pins them to hyena's tailnet IP.
    ntfy = "https://ntfy.${domain}/alerts?template=alertmanager";
    heartbeat = "https://status.${domain}/api/v1/endpoints/cluster_watchdog/external?success=true";
  in {
    gatus.endpoints.alertmanager = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.alertmanager = {
      namespace = "observability";
      helm.releases.alertmanager = {
        chart = lib.helm.downloadHelmChart {
          chart = "alertmanager";
          version = "1.33.1";
          repo = "oci://ghcr.io/prometheus-community/charts";
          chartHash = "sha256-o/zMeLb9GmqTipkv+tOEWX2GuDPxwRERnzTfU3jO5zo=";
        };
        values = {
          baseURL = "https://${hostname}";
          hostAliases = lib.toList {
            ip = "100.64.0.1";
            hostnames = ["ntfy.${domain}" "status.${domain}"];
          };
          config = {
            route = {
              receiver = "default";
              group_wait = "30s";
              group_interval = "5m";
              repeat_interval = "4h";
              routes = [
                # Watchdog always fires; its re-notification is a heartbeat for
                # Gatus on hyena, which alerts via ntfy when it stops.
                {
                  matchers = ["alertname = Watchdog"];
                  receiver = "gatus-heartbeat";
                  group_wait = "0s";
                  group_interval = "1m";
                  repeat_interval = "2m";
                }
                {
                  matchers = ["alertname = InfoInhibitor"];
                  receiver = "null";
                }
              ];
            };
            receivers = [
              {name = "null";}
              {
                name = "gatus-heartbeat";
                webhook_configs = [
                  {
                    url = heartbeat;
                    send_resolved = false;
                    # Not secret: only accepted on hyena's tailnet-only listener.
                    # Must match the external endpoint token in static/hyena.nix.
                    http_config.authorization.credentials = "cluster-watchdog-heartbeat";
                  }
                ];
              }
              {
                name = "default";
                # ntfy's alertmanager template titles firing vs resolved.
                webhook_configs = [
                  {
                    url = ntfy;
                    send_resolved = true;
                  }
                ];
              }
            ];
          };
          configmapReload.enabled = true;
          configmapReload.image.tag = "v0.81.0";
          statefulSet.annotations."reloader.stakater.com/auto" = "true";
        };
      };
      resources.httpRoutes.alertmanager.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "alertmanager";
            port = 9093;
          };
        };
      };
    };
  };
}
