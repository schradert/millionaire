# OAuth2 Proxy — handles Keycloak OIDC login flow, session management,
# and reverse-proxies to upstream apps after authentication.
# An nginx sidecar routes requests to the correct backend based on Host header.
{
  can,
  config,
  ...
}: let
  inherit (config.canivete.meta) domain;
  hostname = "oauth2.${domain}";
in {
  nixidy = {
    config,
    charts,
    lib,
    pkgs,
    ...
  }: let
    yaml = pkgs.formats.yaml {};
    upstreams = config.oauth2Proxy.upstreams;
    namespaces = lib.unique (lib.mapAttrsToList (_: cfg: cfg.namespace) upstreams);
    nginxConf = lib.concatStringsSep "\n" (
      [
        ''
          server {
            listen 8080 default_server;
            server_name _;
            location /healthz { return 200 "ok"; }
            location / { return 404; }
          }
        ''
      ]
      ++ lib.mapAttrsToList (host: cfg: ''
        server {
          listen 8080;
          server_name ${host};
          location / {
            proxy_pass ${cfg.url};
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_http_version 1.1;
            ${lib.optionalString cfg.websocket ''
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
            ''}
          }
        }
      '')
      upstreams
    );
  in {
    options.oauth2Proxy.upstreams = can.attrs.submodule "Host-based upstream routes for oauth2-proxy" ({name, ...}: {
      options.url = can.str "Upstream service URL" {};
      options.namespace = can.str "Namespace where the HTTPRoute lives" {};
      options.websocket = can.bool "Enable WebSocket proxying" {default = false;};
    });
    config = {
      # Keycloak OIDC client
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
                  "--upstream=http://localhost:8080/"
                  "--skip-provider-button=true"
                  "--reverse-proxy=true"
                  "--pass-host-header=true"
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
              containers.router = {
                image.repository = "nginx";
                image.tag = "1.27-alpine";
                ports = lib.toList {
                  name = "router";
                  containerPort = 8080;
                };
                probes.liveness.enabled = true;
                probes.readiness.enabled = true;
                probes.startup.enabled = true;
              };
            };
            service.oauth2-proxy.ports.http.port = 4180;
            configMaps.oauth2-proxy-routes.data."default.conf" = nginxConf;
            persistence.routes = {
              type = "configMap";
              name = "oauth2-proxy-routes";
              advancedMounts.oauth2-proxy.router = lib.toList {
                path = "/etc/nginx/conf.d/default.conf";
                subPath = "default.conf";
                readOnly = true;
              };
            };
          };
        };
        # DragonflyDB for Redis session store
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
                remoteRef.key = "oauth2-proxy/client-secret";
              }
              {
                secretKey = "cookie_secret";
                remoteRef.key = "oauth2-proxy/cookie-secret";
              }
            ];
          };
          # ReferenceGrants: allow HTTPRoutes in app namespaces to reference oauth2-proxy
          referenceGrants = lib.listToAttrs (map (ns: {
              name = "allow-${ns}";
              value.spec = {
                from = lib.toList {
                  group = "gateway.networking.k8s.io";
                  kind = "HTTPRoute";
                  namespace = ns;
                };
                to = lib.toList {
                  group = "";
                  kind = "Service";
                  name = "oauth2-proxy";
                };
              };
            })
            namespaces);
        };
      };
    };
  };
}
