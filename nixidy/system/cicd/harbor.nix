{config, ...}: {
  nixidy = {lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "harbor.${domain}";
    namespace = "cicd";
  in {
    gatus.endpoints.harbor = {
      url = "https://${hostname}/api/v2.0/health";
      group = "internal";
    };

    applications.keycloak.resources.keycloakClients.harbor.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "harbor";
        create = true;
      };
      definition = {
        clientId = "harbor";
        name = "Harbor";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/c/oidc/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };

    applications.harbor = {
      inherit namespace;
      postgres.enable = true;
      volsync.pvcs.harbor-registry.title = "harbor-registry";

      helm.releases.harbor = {
        # Prevent Secret manifests from generating
        transformer = builtins.filter (r: r.kind or "" != "Secret");
        chart = lib.helm.downloadHelmChart {
          chart = "harbor";
          version = "1.18.3";
          repo = "https://helm.goharbor.io";
          chartHash = "sha256-fQdrdJhG33EOaESKRVYmPHVZUg7oVrX5TqLFWw/b6nY=";
        };
        values = {
          externalURL = "https://${hostname}";
          expose.type = "clusterIP";
          expose.tls.enabled = false;
          expose.clusterIP.name = "harbor";
          database = {
            type = "external";
            internal.enabled = false;
            external = {
              host = "harbor-rw";
              port = "5432";
              username = "harbor";
              coreDatabase = "harbor";
              existingSecret = "harbor";
              sslmode = "disable";
            };
          };
          redis = {
            type = "external";
            internal.enabled = false;
            external = {
              addr = "harbor-dragonfly.${namespace}.svc.cluster.local:6379";
              coreDatabaseIndex = "0";
              jobserviceDatabaseIndex = "1";
              registryDatabaseIndex = "2";
              trivyAdapterIndex = "5";
            };
          };
          persistence.persistentVolumeClaim.registry = {
            existingClaim = "harbor-registry";
            size = "100Gi";
          };
          existingSecretAdminPassword = "harbor";
          existingSecretAdminPasswordKey = "HARBOR_ADMIN_PASSWORD";
          existingSecretSecretKey = "harbor";
          core = {
            existingSecret = "harbor-core";
            existingXsrfSecret = "harbor-core";
            secretName = "harbor-core";
          };
          jobservice.existingSecret = "harbor-jobservice";
          registry = {
            existingSecret = "harbor-registry";
            credentials.existingSecret = "harbor-credentials";
          };
          trivy.enabled = true;
          metrics.enabled = true;
          metrics.serviceMonitor.enabled = true;
        };
      };

      resources = {
        dragonflies.harbor-dragonfly.spec = {
          replicas = 1;
          args = ["--proactor_threads" "1"];
          resources.requests.memory = "256Mi";
          resources.limits.memory = "512Mi";
        };
        persistentVolumeClaims.harbor-registry.spec = {
          accessModes = ["ReadWriteOnce"];
          storageClassName = "ceph-block";
          resources.requests.storage = "100Gi";
        };
        httpRoutes.harbor.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "harbor";
              port = 80;
            };
          };
        };
        externalSecrets.harbor.spec = {
          target.template.data = {
            HARBOR_ADMIN_PASSWORD = "{{ .admin_password }}";
            secretKey = "{{ .secret_key }}";
            password = "{{ .db_password }}";
          };
          data = [
            {
              secretKey = "admin_password";
              remoteRef.key = "harbor/admin/password";
              sourceRef.storeRef.name = "bitwarden";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
            {
              secretKey = "secret_key";
              remoteRef.key = "harbor/secret-key";
              sourceRef.storeRef.name = "bitwarden";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
            {
              secretKey = "db_password";
              remoteRef.key = "harbor-app";
              remoteRef.property = "password";
              sourceRef.storeRef.name = "kubernetes-cicd";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
          ];
        };
        externalSecrets.harbor-core.spec = {
          target.template.data = {
            secret = "{{ .secret }}";
            CSRF_KEY = "{{ .csrf_key }}";
            "tls.crt" = "{{ .tls_cert | b64dec }}";
            "tls.key" = "{{ .tls_key | b64dec }}";
          };
          data = [
            {
              secretKey = "secret";
              remoteRef.key = "harbor/core/secret";
              sourceRef.storeRef.name = "bitwarden";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
            {
              secretKey = "csrf_key";
              remoteRef.key = "harbor/core/csrf-key";
              sourceRef.storeRef.name = "bitwarden";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
            {
              secretKey = "tls_cert";
              remoteRef.key = "harbor/core/tls-cert";
              sourceRef.storeRef.name = "bitwarden";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
            {
              secretKey = "tls_key";
              remoteRef.key = "harbor/core/tls-key";
              sourceRef.storeRef.name = "bitwarden";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
          ];
        };
        externalSecrets.harbor-jobservice.spec = {
          target.template.data.JOBSERVICE_SECRET = "{{ .secret }}";
          data = lib.toList {
            secretKey = "secret";
            remoteRef.key = "harbor/jobservice/secret";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          };
        };
        externalSecrets.harbor-registry.spec = {
          target.template.data.REGISTRY_HTTP_SECRET = "{{ .http_secret }}";
          data = lib.toList {
            secretKey = "http_secret";
            remoteRef.key = "harbor/registry/http-secret";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          };
        };
        externalSecrets.harbor-credentials.spec = {
          target.template.data = {
            REGISTRY_PASSWD = "{{ .password }}";
            REGISTRY_HTPASSWD = "{{ .htpasswd }}";
          };
          data = [
            {
              secretKey = "password";
              remoteRef.key = "harbor/registry/password";
              sourceRef.storeRef.name = "bitwarden";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
            {
              secretKey = "htpasswd";
              remoteRef.key = "harbor/registry/htpasswd";
              sourceRef.storeRef.name = "bitwarden";
              sourceRef.storeRef.kind = "ClusterSecretStore";
            }
          ];
        };
        externalSecrets.harbor-oidc.spec.data = lib.toList {
          secretKey = "OIDC_CLIENT_SECRET";
          remoteRef.key = "harbor";
          remoteRef.property = "client-secret";
          sourceRef.storeRef = {
            name = "kubernetes-identity";
            kind = "ClusterSecretStore";
          };
        };

        # Post-deploy Job to configure OIDC auth mode via Harbor API
        jobs.harbor-oidc-config.spec = {
          backoffLimit = 5;
          template.spec = {
            restartPolicy = "OnFailure";
            initContainers = lib.toList {
              name = "wait-for-harbor";
              image = "curlimages/curl:8.13.0";
              command = ["sh" "-c"];
              args = [
                ''
                  until curl -sf http://harbor.${namespace}.svc.cluster.local/api/v2.0/health; do
                    echo "Waiting for Harbor..."
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
                  ADMIN_PASS=$(cat /secrets/harbor/HARBOR_ADMIN_PASSWORD)
                  CLIENT_SECRET=$(cat /secrets/oidc/OIDC_CLIENT_SECRET)
                  curl -sf -X PUT \
                    -u "admin:$ADMIN_PASS" \
                    -H "Content-Type: application/json" \
                    -d "{
                      \"auth_mode\": \"oidc_auth\",
                      \"oidc_name\": \"Keycloak\",
                      \"oidc_endpoint\": \"https://keycloak.${domain}/realms/default\",
                      \"oidc_client_id\": \"harbor\",
                      \"oidc_client_secret\": \"$CLIENT_SECRET\",
                      \"oidc_scope\": \"openid,profile,email,groups\",
                      \"oidc_groups_claim\": \"groups\",
                      \"oidc_admin_group\": \"/admin\",
                      \"oidc_auto_onboard\": true,
                      \"oidc_verify_cert\": true
                    }" \
                    "http://harbor.${namespace}.svc.cluster.local/api/v2.0/configurations"
                ''
              ];
              volumeMounts = [
                {
                  name = "harbor-secrets";
                  mountPath = "/secrets/harbor";
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
                name = "harbor-secrets";
                secret.secretName = "harbor";
              }
              {
                name = "oidc-secrets";
                secret.secretName = "harbor-oidc";
              }
            ];
          };
        };
      };
    };
  };
}
