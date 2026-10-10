{config, ...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain people;
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
      clientSecretRef = {
        name = "windmill";
        create = true;
      };
      definition = {
        clientId = "windmill";
        name = "Windmill";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
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
      # Break-glass admin (admin@windmill.dev) for the bootstrap job
      generatedSecrets.windmill-admin = {
        key = "password";
        bitwarden = "windmill/admin-password";
      };

      helm.releases.windmill = {
        chart = pinned.charts.windmill;
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
            tag = with pinned.images.windmill; "${tag}@${digest}";
            windmillExtra.tag = with pinned.images.windmill-extra; "${tag}@${digest}";
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
        # Windmill migrations expect these roles to exist (the chart provisions them
        # for its bundled Postgres only). CNPG initdb SQL does not re-run on an
        # existing cluster, so reconcile them as managed roles.
        clusters.windmill.spec.managed.roles = [
          {
            name = "windmill_user";
            ensure = "present";
            login = false;
          }
          {
            name = "windmill_admin";
            ensure = "present";
            login = false;
            bypassrls = true;
          }
          {
            name = "windmill";
            ensure = "present";
            login = true;
            passwordSecret.name = "windmill-app";
            inRoles = ["windmill_user" "windmill_admin"];
          }
        ];

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
                property = "client-id";
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
                property = "client-secret";
              };
              sourceRef.storeRef = {
                name = "kubernetes-identity";
                kind = "ClusterSecretStore";
              };
            }
          ];
        };

        # PostSync bootstrap (README "Conventions"): idempotent on every sync.
        # Windmill CE ships no declarative user/SSO config, so this drives the
        # REST API with curl (no Rust mode needed: every step is one call and
        # the checks are status codes or bare booleans, so no JSON parsing).
        #  1. Admin: log in with the generated password; only if that fails use
        #     the factory default (admin@windmill.dev / changeme) to rotate it.
        #  2. tristan: superadmin keyed by email (Windmill identifies SSO users
        #     by email). Created when missing, with an unguessable password and
        #     login type "keycloak" so password login is off for that row and
        #     the Keycloak login resolves to this account.
        #  3. Keycloak OAuth instance setting.
        jobs.windmill-bootstrap = {
          metadata.annotations = {
            "argocd.argoproj.io/hook" = "PostSync";
            "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
          };
          spec = {
            backoffLimit = 6;
            activeDeadlineSeconds = 1200;
            template.spec = let
              container = {
                image = with pinned.images.curl; "${repository}:${tag}@${digest}";
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = ["ALL"];
                };
              };
            in {
              restartPolicy = "OnFailure";
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65534;
                runAsGroup = 65534;
                seccompProfile.type = "RuntimeDefault";
              };
              automountServiceAccountToken = false;
              initContainers = lib.toList (container
                // {
                  name = "wait-for-windmill";
                  command = ["sh" "-c"];
                  args = [
                    ''
                      until curl -sf http://windmill-app.${namespace}.svc.cluster.local:8000/api/version; do
                        echo "Waiting for Windmill..."
                        sleep 10
                      done
                    ''
                  ];
                });
              containers = lib.toList (container
                // {
                  name = "bootstrap";
                  command = ["sh" "-c"];
                  args = [
                    ''
                      set -eu
                      API=http://windmill-app.${namespace}.svc.cluster.local:8000/api
                      ADMIN_EMAIL=admin@windmill.dev
                      ADMIN_PASS=$(cat /secrets/admin/password)
                      CLIENT_ID=$(cat /secrets/oidc/CLIENT_ID)
                      CLIENT_SECRET=$(cat /secrets/oidc/CLIENT_SECRET)
                      USER_EMAIL=${people.my.profiles.personal.email}

                      # call METHOD PATH [JSON] [TOKEN] -> sets CODE and BODY
                      call() {
                        auth="X-Auth: none"
                        [ -z "''${4:-}" ] || auth="Authorization: Bearer $4"
                        if [ -n "''${3:-}" ]; then
                          out=$(curl -s -m 30 -X "$1" -H "Content-Type: application/json" -H "$auth" \
                            -d "$3" -w '\n%{http_code}' "$API$2") || out=$(printf '\n000')
                        else
                          out=$(curl -s -m 30 -X "$1" -H "$auth" \
                            -w '\n%{http_code}' "$API$2") || out=$(printf '\n000')
                        fi
                        CODE=$(printf '%s' "$out" | tail -n 1)
                        BODY=$(printf '%s' "$out" | sed '$d')
                      }
                      fail() { echo "FAILED: $1 (HTTP $CODE)" >&2; exit 1; }

                      # --- 1. admin: generated password first, default only to rotate it
                      login() { call POST /auth/login "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$1\"}"; }
                      login "$ADMIN_PASS"
                      if [ "$CODE" != 200 ]; then
                        echo "generated admin password rejected; trying the factory default to rotate it"
                        login changeme
                        [ "$CODE" = 200 ] || fail "admin login with both generated and default password"
                        call POST /users/setpassword "{\"password\":\"$ADMIN_PASS\"}" "$BODY"
                        [ "$CODE" = 200 ] || fail "set admin password"
                        login "$ADMIN_PASS"
                        [ "$CODE" = 200 ] || fail "admin login after password rotation"
                        echo "admin password rotated"
                      fi
                      TOKEN=$BODY

                      # --- 2. tristan: superadmin, SSO-only, matched by email
                      call GET "/users/exists/$USER_EMAIL" "" "$TOKEN"
                      [ "$CODE" = 200 ] || fail "check for $USER_EMAIL"
                      if [ "$BODY" != true ]; then
                        RANDOM_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)
                        call POST /users/create \
                          "{\"email\":\"$USER_EMAIL\",\"password\":\"$RANDOM_PASS\",\"super_admin\":true,\"name\":\"tristan\",\"skip_email\":true}" "$TOKEN"
                        [ "$CODE" = 201 ] || fail "create $USER_EMAIL"
                        echo "created $USER_EMAIL"
                      fi
                      call POST "/users/update/$USER_EMAIL" '{"is_super_admin":true}' "$TOKEN"
                      [ "$CODE" = 200 ] || fail "grant superadmin to $USER_EMAIL"
                      call POST "/users/set_login_type/$USER_EMAIL" '{"login_type":"keycloak"}' "$TOKEN"
                      [ "$CODE" = 200 ] || fail "set login type for $USER_EMAIL"

                      # --- 3. Keycloak OAuth instance setting (idempotent overwrite)
                      KC=https://keycloak.${domain}/realms/default/protocol/openid-connect
                      call POST /settings/global/oauths "{
                        \"value\": {
                          \"keycloak\": {
                            \"id\": \"$CLIENT_ID\",
                            \"secret\": \"$CLIENT_SECRET\",
                            \"login_config\": {
                              \"auth_url\": \"$KC/auth\",
                              \"token_url\": \"$KC/token\",
                              \"userinfo_url\": \"$KC/userinfo\",
                              \"scopes\": [\"openid\", \"profile\", \"email\"]
                            }
                          }
                        }
                      }" "$TOKEN"
                      [ "$CODE" = 200 ] || fail "set oauths setting"
                      echo "windmill bootstrap complete"
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
                });
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
