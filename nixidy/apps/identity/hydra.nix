{config, ...}: {
  nixidy = {lib, pkgs, ...}: let
    inherit (config.canivete.meta) domain;
    hydraPublicHost = "hydra.${domain}";
    uiHost = "login.${domain}";
  in {
    canivete.crds.hydra-maester = {
      application = "hydra";
      install = false; # CRD is installed by the Hydra Helm chart (hydra-maester sub-chart)
      prefix = "config/crd/bases";
      src = pkgs.fetchFromGitHub {
        owner = "ory";
        repo = "hydra-maester";
        rev = "v0.0.41";
        hash = "sha256-MN3i6KXo8D5LiwfIf9o8RWM+MXfk4XkNHVSAf99LIJ0=";
      };
    };
    applications.hydra = {
      namespace = "identity";
      postgres.enable = true;
      postgres.database = "hydra";
      helm.releases.hydra = {
        chart = lib.helm.downloadHelmChart {
          chart = "hydra";
          version = "0.60.1";
          repo = "https://k8s.ory.sh/helm/charts";
          chartHash = "sha256-KKAxnekw4troP47ffiS8X93xpu3T2F0k5TqjQGG40dU=";
        };
        values = {
          secret.enabled = false;
          hydra.automigration = {
            enabled = true;
            type = "initContainer";
          };
          hydra.config = {
            dsn = "postgres://hydra:$(DB_PASSWORD)@hydra-rw.identity.svc.cluster.local:5432/hydra?sslmode=disable";
            serve.public.cors.enabled = true;
            serve.cookies = {
              same_site_mode = "Lax";
              inherit domain;
            };
            urls = {
              self.issuer = "https://${hydraPublicHost}";
              self.public = "https://${hydraPublicHost}";
              login = "https://${uiHost}/login";
              consent = "https://${uiHost}/consent";
              logout = "https://${uiHost}/logout";
              error = "https://${uiHost}/error";
              post_logout_redirect = "https://${uiHost}/login";
            };
            oidc.subject_identifiers = {
              supported_types = ["public" "pairwise"];
              pairwise.salt = "$(OIDC_SUBJECT_SALT)";
            };
            oauth2.expose_internal_errors = false;
            oauth2.hashers.bcrypt.cost = 12;
            secrets.system = ["$(SYSTEM_SECRET)"];
          };

          deployment.automountServiceAccountToken = true;
          deployment.extraEnv = [
            {
              name = "DB_PASSWORD";
              valueFrom.secretKeyRef = {
                name = "hydra";
                key = "db_password";
              };
            }
            {
              name = "SYSTEM_SECRET";
              valueFrom.secretKeyRef = {
                name = "hydra";
                key = "system_secret";
              };
            }
            {
              name = "OIDC_SUBJECT_SALT";
              valueFrom.secretKeyRef = {
                name = "hydra";
                key = "oidc_salt";
              };
            }
          ];

          job.extraEnv = [
            {
              name = "DB_PASSWORD";
              valueFrom.secretKeyRef = {
                name = "hydra";
                key = "db_password";
              };
            }
          ];
        };
      };
      resources.serviceAccounts.hydra.automountServiceAccountToken = lib.mkForce true;

      resources.externalSecrets.hydra.spec = {
        data = [
          {
            secretKey = "system_secret";
            remoteRef.key = "ory/hydra/system-secret";
            sourceRef.storeRef = {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
          }
          {
            secretKey = "oidc_salt";
            remoteRef.key = "ory/hydra/oidc-subject-salt";
            sourceRef.storeRef = {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
          }
          {
            secretKey = "db_password";
            remoteRef.key = "hydra-app";
            remoteRef.property = "password";
            sourceRef.storeRef = {
              name = "kubernetes-identity";
              kind = "ClusterSecretStore";
            };
          }
        ];
        target.template.data = {
          dsn = "postgres://hydra:{{ .db_password }}@hydra-rw.identity.svc.cluster.local:5432/hydra?sslmode=disable";
          db_password = "{{ .db_password }}";
          system_secret = "{{ .system_secret }}";
          secretsSystem = "{{ .system_secret }}";
          secretsCookie = "{{ .system_secret }}";
          oidc_salt = "{{ .oidc_salt }}";
        };
      };
      resources.httpRoutes.hydra-public.spec = {
        hostnames = [hydraPublicHost];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "hydra-public";
            port = 4444;
          };
        };
      };
    };
  };
}
