# OAuth2 Proxy — handles Keycloak OIDC login flow and session validation.
# Oathkeeper validates session cookies via /oauth2/auth endpoint.
# Browser login redirects go through https://oauth2.{domain}/oauth2/start
{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "oauth2.${domain}";
in {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    applications.keycloak.resources.keycloakClients.oauth2-proxy.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "oauth2-proxy";
        name = "OAuth2 Proxy";
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/oauth2/callback"];
        webOrigins = ["https://*.${domain}"];
        defaultClientScopes = ["openid" "profile" "email"];
        protocolMappers = [
          {
            name = "audience";
            protocol = "openid-connect";
            protocolMapper = "oidc-audience-mapper";
            consentRequired = false;
            config = {
              "included.client.audience" = "oauth2-proxy";
              "id.token.claim" = "true";
              "access.token.claim" = "true";
              "introspection.token.claim" = "true";
            };
          }
        ];
      };
    };

    gatus.endpoints.oauth2-proxy = {
      url = "https://${hostname}/ping";
      group = "internal";
    };
    applications.oauth2-proxy = {
      namespace = "identity";
      helm.releases.oauth2-proxy = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.oauth2-proxy = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.oauth2-proxy = {
              image.repository = "quay.io/oauth2-proxy/oauth2-proxy";
              image.tag = "v7.8.1";
              args = [
                "--http-address=0.0.0.0:4180"
                "--provider=keycloak-oidc"
                "--oidc-issuer-url=https://keycloak.${domain}/realms/default"
                "--client-id=oauth2-proxy"
                "--redirect-url=https://${hostname}/oauth2/callback"
                "--cookie-domain=.${domain}"
                "--cookie-secure=true"
                "--cookie-samesite=lax"
                "--cookie-name=_oauth2_proxy"
                "--email-domain=*"
                "--set-xauthrequest=true"
                "--upstream=static://202"
                "--skip-provider-button=true"
                "--reverse-proxy=true"
                "--whitelist-domain=.${domain}"
                "--session-store-type=redis"
                "--redis-connection-url=redis://oauth2-proxy-dragonfly.identity.svc.cluster.local:6379"
              ];
              envFrom = [{secretRef.name = "oauth2-proxy";}];
              ports = lib.toList {
                name = "http";
                containerPort = 4180;
              };
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/ping";
                spec.httpGet.port = "http";
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/ready";
                spec.httpGet.port = "http";
              };
              probes.startup.enabled = true;
            };
          };
          service.oauth2-proxy.ports.http.port = 4180;
        };
      };
      resources.dragonflies.oauth2-proxy-dragonfly.spec = {
        replicas = 1;
        args = ["--proactor_threads" "1"];
        resources.requests.memory = "320Mi";
        resources.limits.memory = "320Mi";
      };
      resources = {
        httpRoutes.oauth2-proxy.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "oauth2-proxy";
              port = 4180;
            };
          };
        };
        externalSecrets.oauth2-proxy.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.template.data = {
            OAUTH2_PROXY_CLIENT_SECRET = "{{ .client_secret }}";
            OAUTH2_PROXY_COOKIE_SECRET = "{{ .cookie_secret }}";
          };
          data = [
            {
              secretKey = "client_secret";
              # TODO: update to Keycloak-managed secret once Hostzero operator syncs it
              remoteRef.key = "oauth2-proxy/client-secret";
            }
            {
              secretKey = "cookie_secret";
              remoteRef.key = "oauth2-proxy/cookie-secret";
            }
          ];
        };
      };
    };
  };
}
