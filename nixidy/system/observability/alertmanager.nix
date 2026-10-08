{config, ...}: {
  nixidy = {lib, ...}: let
    inherit (config.canivete.meta) domain people;
    hostname = "alertmanager.${domain}";
    # hyena's ntfy + Gatus (static/hyena.nix), reached over the tailnet.
    ntfy = "http://100.64.0.1:2586/alerts?template=alertmanager";
    heartbeat = "http://100.64.0.1:8081/api/v1/endpoints/cluster_watchdog/external?success=true";
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
                webhook_configs = [{url = ntfy;}];
                email_configs = [
                  {
                    to = people.my.profiles.personal.email;
                    from = "noreply@${domain}";
                    smarthost = "stalwart.mail.svc.cluster.local:25";
                    require_tls = false;
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
