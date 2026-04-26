# Chirpstack LoRaWAN network server. Internal-only (no oauth2-proxy — chirpstack
# has its own OIDC integration against Keycloak). Postgres via CNPG, Redis via
# DragonflyDB. MQTT integration talks to the mosquitto broker in this namespace.
{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "chirpstack.${domain}";
    probe = {
      enabled = true;
      custom = true;
      spec.tcpSocket.port = 8080;
    };
  in {
    gatus.endpoints.chirpstack = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Keycloak OIDC client — keycloak-operator syncs client_id/secret to a K8s secret
    applications.keycloak.resources.keycloakClients.chirpstack.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "chirpstack";
        create = true;
      };
      definition = {
        clientId = "chirpstack";
        name = "Chirpstack";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/api/oauth2/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };
    applications.chirpstack = {
      namespace = "home";
      postgres.enable = true;
      helm.releases.chirpstack = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.chirpstack = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.chirpstack = {
              image.repository = "chirpstack/chirpstack";
              image.tag = "4";
              args = ["-c" "/etc/chirpstack/chirpstack.toml"];
              envFrom = [{secretRef.name = "chirpstack";}];
              probes.liveness = probe;
              probes.readiness = probe;
              probes.startup = probe;
            };
          };
          service.chirpstack.ports.http.port = 8080;
          # Chirpstack expands $VAR references in its TOML at startup, so secrets
          # are injected via envFrom above.
          configMaps.chirpstack.data."chirpstack.toml" = ''
            [logging]
              level="info"

            [postgresql]
              dsn="postgres://chirpstack:$CHIRPSTACK_DB_PASSWORD@chirpstack-rw.home.svc.cluster.local:5432/chirpstack?sslmode=disable"
              max_open_connections=10

            [redis]
              servers=["redis://chirpstack-dragonfly.home.svc.cluster.local:6379/"]

            [network]
              enabled_regions=["us915_0"]

            [integration]
              enabled=["mqtt"]

            [integration.mqtt]
              server="tcp://mosquitto.home.svc.cluster.local:1883/"

            [api]
              bind="0.0.0.0:8080"

            [user_authentication.openid_connect]
              enabled=true
              registration_enabled=true
              registration_callback_url="https://${hostname}/api/oauth2/callback"
              provider_url="https://keycloak.${domain}/realms/default"
              client_id="$CHIRPSTACK_OIDC_CLIENT_ID"
              client_secret="$CHIRPSTACK_OIDC_CLIENT_SECRET"
              redirect_url="https://${hostname}/api/oauth2/callback"
              login_label="Login with SSO"
          '';
          persistence.config = {
            type = "configMap";
            name = "chirpstack";
            advancedMounts.chirpstack.chirpstack = [
              {
                path = "/etc/chirpstack/chirpstack.toml";
                subPath = "chirpstack.toml";
                readOnly = true;
              }
            ];
          };
          route.chirpstack = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
      # DragonflyDB for Redis (session state, device state cache)
      resources.dragonflies.chirpstack-dragonfly.spec = {
        replicas = 1;
        resources.requests.memory = "256Mi";
        resources.limits.memory = "512Mi";
      };
      resources.externalSecrets.chirpstack.spec = {
        data = [
          {
            secretKey = "CHIRPSTACK_DB_PASSWORD";
            remoteRef.key = "chirpstack-app";
            remoteRef.property = "password";
            sourceRef.storeRef.name = "kubernetes-home";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "CHIRPSTACK_OIDC_CLIENT_ID";
            remoteRef.key = "chirpstack";
            remoteRef.property = "client-id";
            sourceRef.storeRef.name = "kubernetes-identity";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "CHIRPSTACK_OIDC_CLIENT_SECRET";
            remoteRef.key = "chirpstack";
            remoteRef.property = "client-secret";
            sourceRef.storeRef.name = "kubernetes-identity";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
      };
    };
  };
}
