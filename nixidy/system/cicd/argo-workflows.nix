{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "workflows.${domain}";
in {
  nixidy = {charts, lib, pkgs, ...}: {
    applications.argo-workflows-crds.namespace = "kube-system";
    canivete.crds.argo-workflows = {
      application = "argo-workflows-crds";
      install = true;
      prefix = "manifests/base/crds/minimal";
      src = pkgs.fetchFromGitHub {
        owner = "argoproj";
        repo = "argo-workflows";
        rev = "v4.0.3";
        hash = "sha256-dfsWutL/hrl+/hjwHYBfuJ2iBCnn5Ly6OejqJ0ZHrR0=";
      };
    };

    # Keycloak OIDC client — Hostzero operator syncs secret to K8s
    applications.keycloak.resources.keycloakClients.argo-workflows.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "argo-workflows";
        create = true;
      };
      definition = {
        clientId = "argo-workflows";
        name = "Argo Workflows";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/oauth2/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };

    gatus.endpoints.argo-workflows = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.argo-workflows = {
      namespace = "cicd";
      postgres.enable = true;
      helm.releases.argo-workflows = {
        chart = charts.argoproj.argo-workflows;
        values = {
          server = {
            authModes = ["sso"];
            extraArgs = ["--auth-mode=sso" "--secure"];
            sso = {
              issuer = "https://keycloak.${domain}/realms/default";
              clientId = {
                name = "argo-workflows-oidc";
                key = "CLIENT_ID";
              };
              clientSecret = {
                name = "argo-workflows-oidc";
                key = "CLIENT_SECRET";
              };
              redirectUrl = "https://${hostname}/oauth2/callback";
              scopes = ["openid" "profile" "email" "groups"];
              rbac.enabled = true;
            };
          };
          controller = {
            persistence = {
              archive = true;
              postgresql = {
                host = "argo-workflows-rw";
                port = "5432";
                database = "argo-workflows";
                userNameSecret = {
                  name = "argo-workflows-db";
                  key = "username";
                };
                passwordSecret = {
                  name = "argo-workflows-db";
                  key = "password";
                };
              };
            };
            metricsConfig.enabled = true;
            serviceMonitor.enabled = true;
            workflowDefaults.spec.archiveLogs = true;
          };
          useDefaultArtifactRepo = true;
          artifactRepository.s3 = {
            bucket = "argo-workflows";
            endpoint = "rook-ceph-rgw-ceph-objectstore.storage.svc.cluster.local";
            insecure = true;
            accessKeySecret = {
              name = "argo-workflows-bucket";
              key = "AWS_ACCESS_KEY_ID";
            };
            secretKeySecret = {
              name = "argo-workflows-bucket";
              key = "AWS_SECRET_ACCESS_KEY";
            };
          };
        };
      };
      resources = {
        httpRoutes.argo-workflows.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "argo-workflows-server";
              port = 2746;
            };
          };
        };
        # OIDC client credentials from Keycloak operator
        externalSecrets.argo-workflows-oidc.spec = {
          secretStoreRef = {
            name = "kubernetes-identity";
            kind = "ClusterSecretStore";
          };
          data = [
            {
              secretKey = "CLIENT_ID";
              remoteRef.key = "argo-workflows";
              remoteRef.property = "client-id";
            }
            {
              secretKey = "CLIENT_SECRET";
              remoteRef.key = "argo-workflows";
              remoteRef.property = "client-secret";
            }
          ];
        };
        # Database credentials from CNPG
        externalSecrets.argo-workflows-db.spec = {
          secretStoreRef = {
            name = "kubernetes-cicd";
            kind = "ClusterSecretStore";
          };
          target.template.data = {
            username = "argo-workflows";
            password = "{{ .password }}";
          };
          data = lib.toList {
            secretKey = "password";
            remoteRef.key = "argo-workflows-app";
            remoteRef.property = "password";
          };
        };
        # S3 artifact credentials (Ceph RADOS Gateway)
        externalSecrets.argo-workflows-artifacts.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.name = "argo-workflows-bucket";
          target.template.data = {
            AWS_ACCESS_KEY_ID = "{{ .access_key }}";
            AWS_SECRET_ACCESS_KEY = "{{ .secret_key }}";
          };
          data = [
            {
              secretKey = "access_key";
              remoteRef.key = "argo-workflows/s3/access-key";
            }
            {
              secretKey = "secret_key";
              remoteRef.key = "argo-workflows/s3/secret-key";
            }
          ];
        };
        # Harbor push credentials for CI workflows
        externalSecrets.argo-workflows-harbor.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.name = "argo-workflows-harbor";
          target.template.data."config.json" = builtins.toJSON {
            auths."harbor.${domain}" = {
              username = "{{ .username }}";
              password = "{{ .password }}";
            };
          };
          data = [
            {
              secretKey = "username";
              remoteRef.key = "harbor/robot/username";
            }
            {
              secretKey = "password";
              remoteRef.key = "harbor/robot/password";
            }
          ];
        };
        # CI ServiceAccount for workflow pods
        serviceAccounts.argo-workflows-ci = {};
        clusterRoles.argo-workflows-ci.rules = [
          {
            apiGroups = ["argoproj.io"];
            resources = ["rollouts"];
            verbs = ["get" "patch"];
          }
        ];
        clusterRoleBindings.argo-workflows-ci = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = "argo-workflows-ci";
          };
          subjects = lib.toList {
            kind = "ServiceAccount";
            name = "argo-workflows-ci";
            namespace = "cicd";
          };
        };
        # Reusable CI WorkflowTemplate: clone → build with Nix → push to Harbor → update Rollout
        workflowTemplates.build-and-deploy.spec = {
          serviceAccountName = "argo-workflows-ci";
          entrypoint = "ci-pipeline";
          arguments.parameters = [
            {name = "repo-url";}
            {
              name = "revision";
              default = "main";
            }
            {name = "image-name";}
            {name = "image-tag";}
            {name = "rollout-name";}
            {
              name = "rollout-namespace";
              default = "development";
            }
          ];
          volumeClaimTemplates = lib.toList {
            metadata.name = "workspace";
            spec = {
              accessModes = ["ReadWriteOnce"];
              storageClassName = "ceph-block";
              resources.requests.storage = "10Gi";
            };
          };
          volumes = lib.toList {
            name = "registry-auth";
            secret.secretName = "argo-workflows-harbor";
          };
          templates = [
            {
              name = "ci-pipeline";
              steps = [
                [{name = "clone"; template = "clone";}]
                [{name = "build-push"; template = "build-push";}]
                [{name = "deploy"; template = "deploy";}]
              ];
            }
            {
              name = "clone";
              container = {
                image = "alpine/git:2.47.2";
                command = ["sh" "-c"];
                args = ["git clone {{workflow.parameters.repo-url}} /workspace/src && cd /workspace/src && git checkout {{workflow.parameters.revision}}"];
                volumeMounts = lib.toList {
                  name = "workspace";
                  mountPath = "/workspace";
                };
              };
            }
            {
              name = "build-push";
              container = {
                image = "nixos/nix:2.28.3";
                command = ["sh" "-c"];
                args = [
                  ''
                    cd /workspace/src
                    mkdir -p /etc/nix
                    echo "experimental-features = nix-command flakes" > /etc/nix/nix.conf
                    echo "filter-syscalls = false" >> /etc/nix/nix.conf
                    result=$(nix build ".#legacyPackages.x86_64-linux.images.{{workflow.parameters.image-name}}.copyToRegistry" --no-pure-eval --print-out-paths -L)
                    $result/bin/copy-to-registry
                  ''
                ];
                env = lib.toList {
                  name = "REGISTRY_AUTH_FILE";
                  value = "/registry-auth/config.json";
                };
                volumeMounts = [
                  {
                    name = "workspace";
                    mountPath = "/workspace";
                  }
                  {
                    name = "registry-auth";
                    mountPath = "/registry-auth";
                    readOnly = true;
                  }
                ];
                resources.requests = {
                  cpu = "2";
                  memory = "4Gi";
                };
                resources.limits.memory = "8Gi";
              };
            }
            {
              name = "deploy";
              container = {
                image = "bitnami/kubectl:1.32";
                command = ["sh" "-c"];
                args = [
                  "kubectl argo rollouts set image {{workflow.parameters.rollout-name}} '*=harbor.${domain}/library/{{workflow.parameters.image-name}}:{{workflow.parameters.image-tag}}' -n {{workflow.parameters.rollout-namespace}}"
                ];
              };
            }
          ];
        };
      };
    };
  };
}
