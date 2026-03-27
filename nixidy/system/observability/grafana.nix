{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "grafana.${domain}";
  in {
    gatus.endpoints.grafana = { url = "https://${hostname}"; group = "internal"; };
    applications.grafana = {
      namespace = "observability";
      volsync.pvcs.grafana = {
        title = "grafana";
        uid = 472;
        gid = 472;
      };
      helm.releases.grafana = {
        chart = charts.grafana.grafana;
        values = {
          # TODO dashboards + providers + plugins
          admin.existingSecret = "grafana-admin";
          annotations."reloader.stakater.com/auto" = "true";
          envFromConfigMaps = [{name = "grafana";}];
          persistence.enabled = true;
          serviceAccount.create = true;
          serviceAccount.autoMount = true;
          serviceMonitor.enabled = true;
          sidecar = {
            dashboards.enabled = true;
            dashboards.searchNamespace = "ALL";
            datasources.enabled = true;
            datasources.searchNamespace = "ALL";
          };
        };
      };
      resources = {
        httpRoutes.grafana.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "grafana";
              port = 80;
            };
          };
        };
        configMaps.grafana.data = {
          GF_ANALYTICS_CHECK_FOR_UPDATES = "false";
          GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES = "false";
          GF_ANALYTICS_REPORTING_ENABLED = "false";
          GF_AUTH_ANONYMOUS_ENABLED = "false";
          GF_AUTH_BASIC_ENABLED = "false";
          GF_DATE_FORMATS_USE_BROWSER_LOCALE = "true";
          GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH = "/tmp/dashboards/home.json";
          GF_EXPLORE_ENABLED = "true";
          GF_FEATURE_TOGGLES_ENABLE = "publicDashboards";
          GF_LOG_MODE = "console";
          GF_NEWS_NEWS_FEED_ENABLED = "false";
          GF_SECURITY_COOKIE_SAMESITE = "grafana";
          GF_SERVER_ROOT_URL = "https://${hostname}";
          GF_SMTP_ENABLED = "true";
          GF_SMTP_HOST = "stalwart.mail.svc.cluster.local:25";
          GF_SMTP_FROM_ADDRESS = "noreply@${domain}";
          GF_SMTP_FROM_NAME = "Grafana";
        };
        externalSecrets.grafana-admin.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          data = lib.toList {
            secretKey = "password";
            remoteRef.key = "grafana";
          };
          target.template.data = {
            admin-user = "admin";
            admin-password = "{{ .password }}";
          };
        };
        # FIXME get these permissions right
        replicationSources.volsync--grafana--grafana-src.spec.restic.moverSecurityContext.fsGroup = 472;
      };
    };
  };
}
