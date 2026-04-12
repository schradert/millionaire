{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "hass.${domain}";
in {
  nixidy = {
    charts,
    lib,
    pkgs,
    ...
  }: let
    toYAML = name: obj: builtins.readFile ((pkgs.formats.yaml {}).generate name obj);
    onboardingJson = builtins.toJSON {
      version = 4;
      minor_version = 1;
      key = "onboarding";
      data.done = ["user" "core_config" "analytics" "integration"];
    };
    image = {
      repository = "harbor.${domain}/library/ha";
      tag = "2026.4.1";
      digest = "sha256:a5746c79fa568afde8655c99a7946c66f96bacbe4a2852628727c11bae97279d";
    };
  in {
    gatus.endpoints.ha = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.keycloak.resources.keycloakClients.home-assistant.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "home-assistant";
        name = "Home Assistant";
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        publicClient = true;
        redirectUris = ["https://${hostname}/auth/oidc/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.ha = {
      namespace = "home";
      postgres.enable = true;
      volsync.pvcs.ha-config.title = "ha-config";
      helm.releases.ha = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.ha = {
            annotations."reloader.stakater.com/auto" = "true";
            initContainers.setup = {
              inherit image;
              envFrom = [{secretRef.name = "ha";}];
              command = [
                "sh"
                "-c"
                ''
                  set -e
                  # Skip if already onboarded
                  [ -f /config/.storage/onboarding ] && exit 0

                  # Create initial admin user via HA CLI
                  hass --config /config --script auth add admin "$HASS_ADMIN_PASSWORD"

                  # Mark onboarding as complete
                  mkdir -p /config/.storage
                  echo '${onboardingJson}' > /config/.storage/onboarding

                  echo "Home Assistant onboarded successfully"
                ''
              ];
            };
            containers.ha = {
              inherit image;
              envFrom = [{secretRef.name = "ha";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.ha.ports.http.port = 8123;
          configMaps.ha-config.data."configuration.yaml" = toYAML "configuration.yaml" {
            homeassistant = {
              name = "Homelab";
              external_url = "https://${hostname}";
            };
            http = {
              use_x_forwarded_for = true;
              # Cluster CIDR
              trusted_proxies = ["10.0.0.0/8"];
            };
            auth_oidc = {
              client_id = "keycloak";
              discovery_url = "https://keycloak.${domain}/realms/default/.well-known/openid-configuration";
              display_name = "Keycloak SSO";
              claims.display_name = "name";
              claims.username = "preferred_username";
              claims.groups = "groups";
              roles.admin = "admin";
              features.automatic_person_creation = true;
            };
            lovelace.mode = "storage";
            lovelace.resources = let
              mods = pkgs.home-assistant-custom-lovelace-modules;
              lovelaceModules = with mods; [
                advanced-camera-card
                apexcharts-card
                atomic-calendar-revive
                auto-entities
                battery-state-card
                bubble-card
                button-card
                card-mod
                clock-weather-card
                custom-sidebar
                decluttering-card
                flower-card
                horizon-card
                hourly-weather
                kiosk-mode
                light-entity-card
                material-you-utilities
                mini-graph-card
                mini-media-player
                multiple-entity-row
                mushroom
                navbar-card
                plotly-chart-card
                restriction-card
                sankey-chart
                scheduler-card
                swipe-navigation
                template-entity-row
                universal-remote-card
                versatile-thermostat-ui-card
                weather-card
                weather-chart-card
                zigbee2mqtt-networkmap
              ];
              jsFiles = mod:
                builtins.filter (f: lib.hasSuffix ".js" f)
                (builtins.attrNames (builtins.readDir "${mod}"));
              mkResources = mod:
                map (f: {
                  url = "/local/nixos-lovelace-modules/${f}";
                  type = "module";
                }) (jsFiles mod);
            in
              builtins.concatMap mkResources lovelaceModules;
          };
          persistence.config = {
            type = "persistentVolumeClaim";
            size = "10Gi";
            accessMode = "ReadWriteOnce";
            advancedMounts.ha.ha = [{path = "/config";}];
            advancedMounts.ha.setup = [{path = "/config";}];
          };
          persistence.base-config = {
            type = "configMap";
            name = "ha";
            advancedMounts.ha.ha = [
              {
                path = "/config/configuration.yaml";
                subPath = "configuration.yaml";
                readOnly = false;
              }
            ];
          };
          route.ha = {
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
      resources.externalSecrets.ha.spec = {
        data = [
          {
            secretKey = "HASS_RECORDER_DB_URL";
            remoteRef.key = "ha-app";
            remoteRef.property = "password";
            sourceRef.storeRef.name = "kubernetes-home";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "HASS_ADMIN_PASSWORD";
            remoteRef.key = "ha/admin/password";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
        target.template.data = {
          HASS_RECORDER_DB_URL = "postgresql://ha:{{ .HASS_RECORDER_DB_URL }}@ha-rw.home.svc.cluster.local:5432/ha";
          HASS_ADMIN_PASSWORD = "{{ .HASS_ADMIN_PASSWORD }}";
        };
      };
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://ha.home.svc.cluster.local:8123";
      namespace = "home";
      websocket = true;
    };
  };
}
