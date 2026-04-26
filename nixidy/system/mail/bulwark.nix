{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "webmail.${domain}";
  port = 3000;
  stalwartUrl = "http://stalwart.mail.svc.cluster.local:8080";
in {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/";
      spec.httpGet.port = "http";
    };
  in {
    gatus.endpoints.bulwark = {
      url = "https://${hostname}";
      group = "internal";
    };

    # Bulwark supports native OIDC — register a Keycloak client and let
    # hydra-maester sync the secret into the identity namespace, then mirror
    # it into mail via ExternalSecret + kubernetes-identity ClusterSecretStore.
    applications.keycloak.resources.keycloakClients.bulwark.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "bulwark";
        create = true;
      };
      definition = {
        clientId = "bulwark";
        name = "Bulwark Webmail";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/*"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    applications.bulwark = {
      namespace = "mail";
      # Encrypted per-user settings live at /data/settings
      volsync.pvcs.bulwark.title = "bulwark";
      helm.releases.bulwark = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.bulwark = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.bulwark = {
              image = {
                repository = "ghcr.io/bulwarkmail/webmail";
                tag = "v1.4.9";
                digest = "sha256:9f5ef45ee046d6a33336e2963016538640589afbf8618cef61e340a57dbd8770";
              };
              env = {
                JMAP_SERVER_URL = stalwartUrl;
                APP_NAME = "Homelab Mail";
                STALWART_FEATURES = "true";
                OAUTH_ENABLED = "true";
                OAUTH_ISSUER_URL = "https://keycloak.${domain}/realms/default";
                SETTINGS_SYNC_ENABLED = "true";
                SETTINGS_DATA_DIR = "/data/settings";
                LOG_FORMAT = "json";
              };
              envFrom = [{secretRef.name = "bulwark";}];
              ports = lib.toList {
                name = "http";
                containerPort = port;
              };
              probes.liveness = probe {};
              probes.readiness = probe {};
              probes.startup = probe {
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };
          service.bulwark.ports.http.port = port;
          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            advancedMounts.bulwark.bulwark = [{path = "/data";}];
          };
        };
      };
      resources = {
        externalSecrets.bulwark.spec.data = [
          {
            secretKey = "SESSION_SECRET";
            remoteRef.key = "bulwark/session-secret";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "OAUTH_CLIENT_ID";
            remoteRef.key = "bulwark";
            remoteRef.property = "client-id";
            sourceRef.storeRef.name = "kubernetes-identity";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "OAUTH_CLIENT_SECRET";
            remoteRef.key = "bulwark";
            remoteRef.property = "client-secret";
            sourceRef.storeRef.name = "kubernetes-identity";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
        httpRoutes.bulwark.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "bulwark";
              inherit port;
            };
          };
        };
      };
    };
  };
}
