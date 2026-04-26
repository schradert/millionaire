{config, ...}: {
  nixidy = {lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "windmill.${domain}";
    namespace = "development";
  in {
    gatus.endpoints.windmill = {
      url = "https://${hostname}/api/version";
      group = "internal";
    };

    # Keycloak OIDC client — operator syncs secret to K8s
    applications.keycloak.resources.keycloakClients.windmill.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "windmill";
        name = "Windmill";
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/user/login_callback/keycloak"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };

    applications.windmill = {
      inherit namespace;
      postgres.enable = true;

      helm.releases.windmill = {
        chart = lib.helm.downloadHelmChart {
          chart = "windmill";
          version = "4.0.119";
          repo = "https://windmill-labs.github.io/windmill-helm-charts";
          chartHash = "sha256-197D3CuiggeCCojavZENj5eWSxAkGApv5RJPXz8hazw=";
        };
        values = {
          # Disable bundled demo PostgreSQL — use CNPG
          postgresql.enabled = false;

          # Disable bundled MinIO — not needed at homelab scale
          minio.enabled = false;

          # Disable chart ingress — we use HTTPRoute
          ingress.enabled = false;

          # Enable chart's built-in HTTPRoute support
          httproute = {
            enabled = true;
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };

          windmill = {
            baseDomain = hostname;
            baseProtocol = "https";
            appReplicas = 1;
            extraReplicas = 1;
            multiplayerReplicas = 0;

            # Database credentials via ExternalSecret
            databaseUrlSecretName = "windmill-db";
            databaseUrlSecretKey = "DATABASE_URL";

            # Worker groups — single default + native for homelab
            workerGroups = [
              {
                name = "default";
                replicas = 2;
                resources.limits.memory = "2Gi";
                resources.requests = {
                  cpu = "500m";
                  memory = "1Gi";
                };
              }
              {
                name = "native";
                replicas = 1;
                resources.limits.memory = "1Gi";
                resources.requests = {
                  cpu = "100m";
                  memory = "256Mi";
                };
                extraEnv = [
                  {
                    name = "NATIVE_MODE";
                    value = "true";
                  }
                  {
                    name = "SLEEP_QUEUE";
                    value = "200";
                  }
                ];
              }
            ];

            app.annotations."reloader.stakater.com/auto" = "true";

            indexer = {
              enabled = true;
              resources.limits.memory = "1Gi";
              resources.limits.ephemeral-storage = "10Gi";
            };
          };

          # Prometheus metrics (EE flag, but metricsAddr enables the /metrics endpoint)
          enterprise.metricsAddr = "true";
        };
      };

      resources = {
        # Database URL composed from CNPG-generated password
        externalSecrets.windmill-db.spec = {
          target.template.data = {
            DATABASE_URL = "postgresql://windmill:{{ .password }}@windmill-rw.${namespace}.svc.cluster.local:5432/windmill?sslmode=disable";
          };
          data = lib.toList {
            secretKey = "password";
            remoteRef = {
              key = "windmill-app";
              property = "password";
            };
            sourceRef.storeRef = {
              name = "kubernetes-${namespace}";
              kind = "ClusterSecretStore";
            };
          };
        };

        # OIDC client credentials from keycloak-operator
        externalSecrets.windmill-oidc.spec = {
          target.template.data = {
            CLIENT_ID = "{{ .clientId }}";
            CLIENT_SECRET = "{{ .clientSecret }}";
          };
          data = [
            {
              secretKey = "clientId";
              remoteRef = {
                key = "windmill";
                property = "CLIENT_ID";
              };
              sourceRef.storeRef = {
                name = "kubernetes-identity";
                kind = "ClusterSecretStore";
              };
            }
            {
              secretKey = "clientSecret";
              remoteRef = {
                key = "windmill";
                property = "CLIENT_SECRET";
              };
              sourceRef.storeRef = {
                name = "kubernetes-identity";
                kind = "ClusterSecretStore";
              };
            }
          ];
        };

        # Admin password from Bitwarden for initial bootstrap
        externalSecrets.windmill-admin.spec = {
          secretStoreRef = {
            name = "bitwarden";
            kind = "ClusterSecretStore";
          };
          data = lib.toList {
            secretKey = "password";
            remoteRef.key = "windmill/admin/password";
          };
        };

        # Post-deploy Job: configure Keycloak OIDC SSO via Windmill API
        jobs.windmill-oidc-config.spec = {
          backoffLimit = 5;
          template.spec = {
            restartPolicy = "OnFailure";
            initContainers = lib.toList {
              name = "wait-for-windmill";
              image = "curlimages/curl:8.13.0";
              command = ["sh" "-c"];
              args = [
                ''
                  until curl -sf http://windmill-app.${namespace}.svc.cluster.local:8000/api/version; do
                    echo "Waiting for Windmill..."
                    sleep 10
                  done
                ''
              ];
            };
            containers = lib.toList {
              name = "configure-oidc";
              image = "curlimages/curl:8.13.0";
              command = ["sh" "-c"];
              args = [
                ''
                  ADMIN_PASS=$(cat /secrets/admin/password)
                  CLIENT_ID=$(cat /secrets/oidc/CLIENT_ID)
                  CLIENT_SECRET=$(cat /secrets/oidc/CLIENT_SECRET)

                  # Initial login with default credentials to get bootstrap token
                  TOKEN=$(curl -sf -X POST \
                    -H "Content-Type: application/json" \
                    -d "{\"email\":\"admin@windmill.dev\",\"password\":\"changeme\"}" \
                    "http://windmill-app.${namespace}.svc.cluster.local:8000/api/auth/login")

                  # Update admin password
                  curl -sf -X POST \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $TOKEN" \
                    -d "{\"password\":\"$ADMIN_PASS\"}" \
                    "http://windmill-app.${namespace}.svc.cluster.local:8000/api/users/setpassword" || true

                  # Re-login with new password
                  TOKEN=$(curl -sf -X POST \
                    -H "Content-Type: application/json" \
                    -d "{\"email\":\"admin@windmill.dev\",\"password\":\"$ADMIN_PASS\"}" \
                    "http://windmill-app.${namespace}.svc.cluster.local:8000/api/auth/login")

                  # Configure Keycloak OIDC SSO
                  curl -sf -X POST \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $TOKEN" \
                    -d "{
                      \"value\": {
                        \"keycloak\": {
                          \"id\": \"$CLIENT_ID\",
                          \"secret\": \"$CLIENT_SECRET\",
                          \"login_config\": {
                            \"auth_url\": \"https://keycloak.${domain}/realms/default/protocol/openid-connect/auth\",
                            \"token_url\": \"https://keycloak.${domain}/realms/default/protocol/openid-connect/token\",
                            \"userinfo_url\": \"https://keycloak.${domain}/realms/default/protocol/openid-connect/userinfo\",
                            \"scopes\": [\"openid\", \"profile\", \"email\", \"offline_access\"]
                          }
                        }
                      }
                    }" \
                    "http://windmill-app.${namespace}.svc.cluster.local:8000/api/settings/global/oauths"
                ''
              ];
              volumeMounts = [
                {
                  name = "admin-secrets";
                  mountPath = "/secrets/admin";
                  readOnly = true;
                }
                {
                  name = "oidc-secrets";
                  mountPath = "/secrets/oidc";
                  readOnly = true;
                }
              ];
            };
            volumes = [
              {
                name = "admin-secrets";
                secret.secretName = "windmill-admin";
              }
              {
                name = "oidc-secrets";
                secret.secretName = "windmill-oidc";
              }
            ];
          };
        };

        # Prometheus PodMonitor for worker metrics
        podMonitors.windmill-workers.spec = {
          podMetricsEndpoints = lib.toList {
            port = "metrics";
            interval = "30s";
          };
          selector.matchLabels."app.kubernetes.io/name" = "windmill";
        };

        # Grafana dashboard auto-discovered by sidecar
        configMaps.windmill-dashboard = {
          metadata.labels.grafana_dashboard = "1";
          data."windmill.json" = builtins.readFile ./windmill-dashboard.json;
        };
      };
    };
  };
}
