{config, ...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "grafana.${domain}";
    oidc = "https://keycloak.${domain}/realms/default/protocol/openid-connect";
  in {
    # Keycloak SSO (generic OAuth). Group admin -> Grafana server admin, everyone
    # else Viewer. The local `admin` (Bitwarden `grafana`) stays as break-glass.
    applications.keycloak.resources.keycloakClients.grafana.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "grafana";
        create = true;
      };
      definition = {
        clientId = "grafana";
        name = "Grafana";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/login/generic_oauth"];
        webOrigins = ["https://${hostname}"];
        attributes."post.logout.redirect.uris" = "https://${hostname}/login";
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    gatus.endpoints.grafana = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.grafana = {
      namespace = "observability";
      volsync.pvcs.grafana = {
        title = "grafana";
        uid = 472;
        gid = 472;
      };
      helm.releases.grafana = {
        chart = pinned.charts.grafana;
        values = {
          image.sha = lib.removePrefix "sha256:" pinned.images.grafana.digest;
          sidecar.image.sha = lib.removePrefix "sha256:" pinned.images.grafana-sidecar.digest;
          initChownData.image.sha = lib.removePrefix "sha256:" pinned.images.grafana-busybox.digest;
          # TODO dashboards + providers + plugins
          admin.existingSecret = "grafana-admin";
          # RWO volume: a rolling update deadlocks on Multi-Attach.
          deploymentStrategy.type = "Recreate";
          annotations."reloader.stakater.com/auto" = "true";
          envFromConfigMaps = [{name = "grafana";}];
          envFromSecrets = [{name = "grafana-oidc";}];
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
          GF_AUTH_GENERIC_OAUTH_ENABLED = "true";
          GF_AUTH_GENERIC_OAUTH_NAME = "Keycloak";
          GF_AUTH_GENERIC_OAUTH_CLIENT_ID = "grafana";
          GF_AUTH_GENERIC_OAUTH_SCOPES = "openid profile email groups";
          GF_AUTH_GENERIC_OAUTH_AUTH_URL = "${oidc}/auth";
          GF_AUTH_GENERIC_OAUTH_TOKEN_URL = "${oidc}/token";
          GF_AUTH_GENERIC_OAUTH_API_URL = "${oidc}/userinfo";
          GF_AUTH_GENERIC_OAUTH_SIGNOUT_REDIRECT_URL = "${oidc}/logout?client_id=grafana&post_logout_redirect_uri=https%3A%2F%2F${hostname}%2Flogin";
          GF_AUTH_GENERIC_OAUTH_USE_PKCE = "true";
          GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP = "true";
          GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH = "preferred_username";
          GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH = "email";
          GF_AUTH_GENERIC_OAUTH_GROUPS_ATTRIBUTE_PATH = "groups";
          GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH = "contains(groups[*], 'admin') && 'GrafanaAdmin' || 'Viewer'";
          GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN = "true";
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
        externalSecrets.grafana-oidc.spec = {
          target.template.data.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = "{{ .client_secret }}";
          data = lib.toList {
            secretKey = "client_secret";
            remoteRef.key = "grafana";
            remoteRef.property = "client-secret";
            sourceRef.storeRef.name = "kubernetes-identity";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          };
        };
        # FIXME get these permissions right
        replicationSources.volsync--grafana--grafana-src.spec.restic.moverSecurityContext.fsGroup = 472;
      };
    };
  };
}
