{config, ...}: {
  nixidy = {
    lib,
    pkgs,
    ...
  }: let
    inherit (config.canivete.meta) domain;
  in {
    applications.oathkeeper-crds.namespace = "kube-system";
    canivete.crds.oathkeeper = {
      application = "oathkeeper-crds";
      install = true;
      prefix = "config/crd/bases";
      match = ".*_.*\\.yaml$";
      src = pkgs.fetchFromGitHub {
        owner = "ory";
        repo = "oathkeeper-maester";
        rev = "v0.1.13";
        hash = "sha256-V0oTW82oVReJUXQnlyTlh0MWXjwbGu75ZkU4CHu23KU=";
      };
    };
    applications.oathkeeper = {
      namespace = "identity";

      helm.releases.oathkeeper = {
        chart = lib.helm.downloadHelmChart {
          chart = "oathkeeper";
          version = "0.60.1";
          repo = "https://k8s.ory.sh/helm/charts";
          chartHash = "sha256-3szb/byf85oxDwB03yr3GDX5nIg7f17z6D2/6nnQQ2k=";
        };
        values = {
          oathkeeper-maester = {
            enabled = true;
            maesterExtraResources = "";
          };

          oathkeeper.config = {
            authenticators = {
              cookie_session = {
                enabled = true;
                config = {
                  check_session_url = "http://kratos-public.identity.svc.cluster.local:4433/sessions/whoami";
                  preserve_path = true;
                  extra_from = "@this";
                  subject_from = "identity.id";
                  only = ["ory_kratos_session"];
                };
              };
              bearer_token = {
                enabled = true;
                config = {
                  check_session_url = "http://kratos-public.identity.svc.cluster.local:4433/sessions/whoami";
                  token_from.header = "Authorization";
                  force_method = "GET";
                };
              };
              oauth2_introspection = {
                enabled = true;
                config = {
                  introspection_url = "http://hydra-admin.identity.svc.cluster.local:4445/admin/oauth2/introspect";
                  cache = {
                    enabled = true;
                    ttl = "300s";
                  };
                };
              };
              anonymous.enabled = true;
              noop.enabled = true;
            };

            authorizers = {
              allow.enabled = true;
              deny.enabled = true;
            };

            mutators = {
              header = {
                enabled = true;
                config.headers = {
                  "X-User-Id" = "{{ print .Subject }}";
                  "X-User-Email" = "{{ print .Extra.identity.traits.email }}";
                  "X-Auth-Request-Preferred-Username" = "{{ print .Extra.identity.traits.email }}";
                  "X-Auth-Request-Email" = "{{ print .Extra.identity.traits.email }}";
                };
              };
              noop.enabled = true;
              id_token = {
                enabled = true;
                config = {
                  issuer_url = "https://oathkeeper.${domain}";
                  jwks_url = "file:///etc/oathkeeper/id_token.jwks.json";
                };
              };
            };

            errors.handlers = {
              redirect = {
                enabled = true;
                config = {
                  to = "https://login.${domain}/login";
                  when = [
                    {
                      error = ["unauthorized" "forbidden"];
                      request.header.accept = ["text/html"];
                    }
                  ];
                };
              };
              json = {
                enabled = true;
                config.verbose = false;
              };
            };

            access_rules.repositories = ["inline://"];
          };

          deployment = {
            extraVolumes = [
              {
                name = "jwks";
                secret.secretName = "oathkeeper-jwks";
              }
            ];
            extraVolumeMounts = [
              {
                name = "jwks";
                mountPath = "/etc/oathkeeper/id_token.jwks.json";
                subPath = "jwks.json";
                readOnly = true;
              }
            ];
          };
        };
      };

      # JWK set for ID token signing
      resources.externalSecrets.oathkeeper-jwks.spec.data = lib.toList {
        secretKey = "jwks.json";
        remoteRef.key = "ory/oathkeeper/mutator-id-token-jwks";
        sourceRef.storeRef = {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
      };

      # ReferenceGrant: allow HTTPRoutes in other namespaces to reference oathkeeper-proxy
      resources.referenceGrants.allow-finance.spec = {
        from = [
          {
            group = "gateway.networking.k8s.io";
            kind = "HTTPRoute";
            namespace = "finance";
          }
        ];
        to = [
          {
            group = "";
            kind = "Service";
            name = "oathkeeper-proxy";
          }
        ];
      };
    };
  };
}
