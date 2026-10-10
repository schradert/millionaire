{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "workflows.${domain}";
  nixImage = "nixos/nix:2.28.3";
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: {
    applications.argo-workflows-crds.namespace = "kube-system";
    canivete.crds.argo-workflows = {
      application = "argo-workflows-crds";
      install = true;
      prefix = "manifests/base/crds/minimal";
      match = "argoproj\\.io_.*\\.yaml$"; # only the real CRD files, not kustomization.yaml
      src = pinned.argo-workflows;
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
      # S3 artifact bucket on Ceph RGW. Rook creates the Secret and ConfigMap
      # "argo-workflows-bucket" (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY),
      # exactly what artifactRepository.s3 reads below.
      objects = lib.toList {
        apiVersion = "objectbucket.io/v1alpha1";
        kind = "ObjectBucketClaim";
        metadata.name = "argo-workflows-bucket";
        spec = {
          bucketName = "argo-workflows";
          storageClassName = "ceph-bucket";
        };
      };
      helm.releases.argo-workflows = {
        chart = charts.argoproj.argo-workflows;
        values = {
          server = {
            authModes = ["sso"];
            extraArgs = ["--auth-mode=sso" "--secure"];
            sso = {
              enabled = true;
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
            # RBAC-only: scopes the chart's per-namespace workflow Role (and
            # avoids a duplicate Role render against the release namespace);
            # the controller still watches cluster-wide.
            workflowNamespaces = ["cicd"];
            persistence = {
              archive = true;
              postgresql = {
                host = "argo-workflows-rw";
                port = 5432;
                database = "argo-workflows";
                tableName = "argo_workflows";
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
        # Harbor push credentials for CI workflows. Same robot secret that
        # harbor-init applies to the "push" robot account (harbor/robot/secret);
        # containers-auth wants a base64 "auth" field, not username/password.
        externalSecrets.argo-workflows-harbor.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.name = "argo-workflows-harbor";
          target.template.data."config.json" = ''{"auths":{"harbor.${domain}":{"auth":"{{ printf "robot$push:%s" .password | b64enc }}"}}}'';
          data = lib.toList {
            secretKey = "password";
            remoteRef.key = "harbor/robot/secret";
          };
        };
        # CI ServiceAccount for workflow pods
        serviceAccounts.argo-workflows-ci = {};
        clusterRoles.argo-workflows-ci.rules = [
          {
            apiGroups = ["argoproj.io"];
            resources = ["rollouts"];
            verbs = ["get" "patch"];
          }
          # The argo-workflows v4 executor (wait container) reports step
          # results via WorkflowTaskResults; without this every workflow
          # errors at runtime. The chart's own workflow Role only binds the
          # default "argo-workflow" SA, which we don't use.
          {
            apiGroups = ["argoproj.io"];
            resources = ["workflowtaskresults"];
            verbs = ["create" "patch"];
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
        # Persistent /nix for image builds: first run seeds it from the nix
        # image, later runs reuse substituted + built store paths.
        persistentVolumeClaims.image-build-nix.spec = {
          accessModes = ["ReadWriteOnce"];
          storageClassName = "ceph-block";
          resources.requests.storage = "60Gi";
        };
        # Publish the flake's nix2container images (modules/images.nix) to
        # Harbor. Idempotent: an image is only built+pushed when its
        # <name>:<tag> is missing from the registry, so the tag in images.nix
        # is the release switch. Triggered by the image-poll sensor.
        workflowTemplates.image-publish.spec = {
          serviceAccountName = "argo-workflows-ci";
          entrypoint = "publish";
          archiveLogs = false;
          activeDeadlineSeconds = 7200;
          ttlStrategy = {
            secondsAfterSuccess = 600;
            secondsAfterFailure = 86400;
          };
          # One build at a time: a single RWO /nix cache and bounded node load.
          synchronization.mutexes = lib.toList {name = "image-publish";};
          arguments.parameters = [
            {
              name = "repo-url";
              value = "https://github.com/schradert/millionaire.git";
            }
            {
              name = "revision";
              value = "main";
            }
            {
              name = "images";
              value = "";
            }
            {
              name = "force";
              value = "false";
            }
          ];
          volumes = [
            {
              name = "nix";
              persistentVolumeClaim.claimName = "image-build-nix";
            }
            {
              name = "registry-auth";
              secret.secretName = "argo-workflows-harbor";
            }
          ];
          templates = lib.toList {
            name = "publish";
            # Workers only: keep builds off the etcd control-plane nodes.
            affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = lib.toList {
              matchExpressions = [
                {
                  key = "kubernetes.io/hostname";
                  operator = "In";
                  values = ["bonobo" "chinchilla"];
                }
                {
                  key = "kubernetes.io/arch";
                  operator = "In";
                  values = ["amd64"];
                }
              ];
            };
            initContainers = lib.toList {
              name = "seed-nix-store";
              image = nixImage;
              command = ["sh" "-c"];
              args = ["[ -e /cache/.seeded ] || { cp -a /nix/. /cache/ && touch /cache/.seeded; }"];
              volumeMounts = lib.toList {
                name = "nix";
                mountPath = "/cache";
              };
            };
            container = {
              image = nixImage;
              command = ["bash" "-ec"];
              args = [
                (builtins.readFile ./image-publish.sh)
                "image-publish"
                "{{workflow.parameters.repo-url}}"
                "{{workflow.parameters.revision}}"
                "{{workflow.parameters.images}}"
                "{{workflow.parameters.force}}"
              ];
              env = lib.toList {
                name = "REGISTRY_AUTH_FILE";
                value = "/registry-auth/config.json";
              };
              volumeMounts = [
                {
                  name = "nix";
                  mountPath = "/nix";
                }
                {
                  name = "registry-auth";
                  mountPath = "/registry-auth";
                  readOnly = true;
                }
              ];
              resources.requests = {
                cpu = "1";
                memory = "4Gi";
              };
              resources.limits.memory = "12Gi";
            };
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
                [
                  {
                    name = "clone";
                    template = "clone";
                  }
                ]
                [
                  {
                    name = "build-push";
                    template = "build-push";
                  }
                ]
                [
                  {
                    name = "deploy";
                    template = "deploy";
                  }
                ]
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
