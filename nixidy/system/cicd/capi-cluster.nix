# Scoped-CAPI cluster resources for cloud-burst workers.
#
# The home RKE2 cluster is both management and workload cluster. There is NO
# controlPlaneRef (the control plane is Pulumi-managed home hardware — CAPI
# has no infrastructure API for it): ControlPlaneInitialized stays false
# forever, which is cosmetic and blocks only bootstrap providers (bypassed
# here via bootstrap.dataSecretName). Mechanics this relies on are individual
# documented contracts:
#   - dataSecretName: user-provided bootstrap Secret, no bootstrap provider
#   - pre-created <cluster>-kubeconfig Secret is honored, never overwritten
#   - Machine<->Node matching via providerID (the image self-sets
#     provider-id=hcloud://<id>; no CCM — in a hybrid cluster a CCM's
#     node-lifecycle controller could delete home Node objects)
{...}: {
  nixidy = {
    lib,
    pkgs,
    pulumi,
    ...
  }: let
    clusterName = "millionaire";
    # sirver's tailnet IPv4, captured by pulumi after the tailnet deploy;
    # substituted into the rendered manifests by vals at switch time.
    sirverTailnetIp = pulumi.vals "command:local:Command" "sirver_tailnet_ip" "stdout";
    skipDryRun = {
      "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true";
    };
  in {
    # Types only — the operator installs the providers' CRDs at runtime.
    canivete.crds.capi = {
      application = "capi-cluster";
      prefix = "config/crd/bases";
      match = ".*_(clusters|machinedeployments|machinehealthchecks)\\.yaml";
      # CloudNativePG's Cluster kind already owns resources.clusters.
      attrNameOverrides."clusters.cluster.x-k8s.io" = "capiClusters";
      src = pkgs.fetchFromGitHub {
        owner = "kubernetes-sigs";
        repo = "cluster-api";
        rev = "v1.13.2";
        hash = "sha256-qV96VA3kPzQSyn4Ff3l7Qh0BL9qKXGNax1rVAo+629g=";
      };
    };
    canivete.crds.caph = {
      application = "capi-cluster";
      prefix = "config/crd/bases";
      match = ".*_(hetznerclusters|hcloudmachinetemplates)\\.yaml";
      src = pkgs.fetchFromGitHub {
        owner = "syself";
        repo = "cluster-api-provider-hetzner";
        rev = "v1.1.6";
        hash = "sha256-FfwzFqZ9Qva2lG+xFsBwC2D2iuBVHC6lJ62oD75Yibk=";
      };
    };

    applications.capi-cluster = {
      namespace = "capi";
      # The autoscaler owns MachineDeployment replicas at runtime.
      ignoreDifferences = lib.toList {
        group = "cluster.x-k8s.io";
        kind = "MachineDeployment";
        jsonPointers = ["/spec/replicas"];
      };

      resources = {
        # --- Secrets from Bitwarden ---
        externalSecrets.capi-hetzner.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.name = "hetzner";
          data = lib.toList {
            secretKey = "hcloud";
            remoteRef.key = "hetzner/api-token/capi";
          };
        };
        # CAPI bootstrap data: a complete cloud-init document. Workers consume
        # exactly three files (see static/cloud-worker.nix); the sentinel tells
        # CAPI bootstrap succeeded. b64 content keeps YAML quoting honest.
        externalSecrets.cloud-worker-bootstrap.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.name = "cloud-worker-bootstrap";
          target.template = {
            metadata.labels."cluster.x-k8s.io/cluster-name" = clusterName;
            data = {
              format = "cloud-config";
              value = ''
                #cloud-config
                write_files:
                  - path: /var/lib/cloud-worker/ts-authkey
                    permissions: "0600"
                    encoding: b64
                    content: {{ .tsAuthkey | b64enc }}
                  - path: /var/lib/cloud-worker/rke2-token
                    permissions: "0600"
                    encoding: b64
                    content: {{ .rke2Token | b64enc }}
                  - path: /var/lib/cloud-worker/sirver-ip
                    permissions: "0644"
                    encoding: b64
                    content: {{ .sirverIp | b64enc }}
                runcmd:
                  - mkdir -p /run/cluster-api && touch /run/cluster-api/bootstrap-success.complete
              '';
            };
          };
          data = [
            {
              secretKey = "tsAuthkey";
              remoteRef.key = "headscale/preauth-key/k8s-cloud-worker";
            }
            {
              secretKey = "rke2Token";
              remoteRef.key = "rke2/agent-token";
            }
            {
              secretKey = "sirverIp";
              remoteRef.key = "headscale/node-ip/sirver";
            }
          ];
        };

        # --- Workload-cluster access for CAPI controllers ---
        # Management == workload, but CAPI still dials the "workload" API via
        # the <cluster>-kubeconfig Secret (NodeRef matching, drain, node
        # deletion). Assemble it from a long-lived ServiceAccount token; the
        # cluster controller honors a pre-existing Secret and never overwrites.
        serviceAccounts.capi-workload = {};
        clusterRoles.capi-workload.rules = [
          {
            apiGroups = [""];
            resources = ["nodes"];
            verbs = ["get" "list" "watch" "patch" "update" "delete"];
          }
          {
            apiGroups = [""];
            resources = ["pods"];
            verbs = ["get" "list" "watch"];
          }
          {
            apiGroups = [""];
            resources = ["pods/eviction"];
            verbs = ["create"];
          }
          {
            apiGroups = [""];
            resources = ["namespaces"];
            verbs = ["get" "list" "watch"];
          }
          {
            apiGroups = ["storage.k8s.io"];
            resources = ["volumeattachments"];
            verbs = ["get" "list" "watch"];
          }
        ];
        clusterRoleBindings.capi-workload = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = "capi-workload";
          };
          subjects = lib.toList {
            kind = "ServiceAccount";
            name = "capi-workload";
            namespace = "capi";
          };
        };
        # Legacy token Secret: kube-controller-manager populates token+ca.crt.
        secrets.capi-workload-token = {
          metadata.annotations."kubernetes.io/service-account.name" = "capi-workload";
          type = "kubernetes.io/service-account-token";
        };

        # ESO reads the token Secret back and templates the kubeconfig.
        serviceAccounts.eso-kubeconfig-reader = {};
        roles.eso-kubeconfig-reader.rules = lib.toList {
          apiGroups = [""];
          resources = ["secrets"];
          verbs = ["get" "list" "watch"];
        };
        roleBindings.eso-kubeconfig-reader = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "eso-kubeconfig-reader";
          };
          subjects = lib.toList {
            kind = "ServiceAccount";
            name = "eso-kubeconfig-reader";
            namespace = "capi";
          };
        };
        secretStores.capi-local.spec.provider.kubernetes = {
          remoteNamespace = "capi";
          server = {
            url = "https://kubernetes.default.svc";
            caProvider = {
              type = "ConfigMap";
              name = "kube-root-ca.crt";
              key = "ca.crt";
              namespace = "capi";
            };
          };
          auth.serviceAccount.name = "eso-kubeconfig-reader";
        };
        externalSecrets.millionaire-kubeconfig.spec = {
          secretStoreRef.name = "capi-local";
          secretStoreRef.kind = "SecretStore";
          target.name = "${clusterName}-kubeconfig";
          target.template = {
            metadata.labels."cluster.x-k8s.io/cluster-name" = clusterName;
            data.value = ''
              apiVersion: v1
              kind: Config
              clusters:
                - name: ${clusterName}
                  cluster:
                    server: https://kubernetes.default.svc
                    certificate-authority-data: {{ .caCrt | b64enc }}
              users:
                - name: capi-workload
                  user:
                    token: {{ .token }}
              contexts:
                - name: ${clusterName}
                  context:
                    cluster: ${clusterName}
                    user: capi-workload
              current-context: ${clusterName}
            '';
          };
          data = [
            {
              secretKey = "token";
              remoteRef.key = "capi-workload-token";
              remoteRef.property = "token";
            }
            {
              secretKey = "caCrt";
              remoteRef.key = "capi-workload-token";
              remoteRef.property = "ca.crt";
            }
          ];
        };

        # --- The cluster (anchor object; control plane externally managed) ---
        capiClusters.${clusterName} = {
          metadata.annotations = skipDryRun;
          spec = {
            clusterNetwork = {
              pods.cidrBlocks = ["10.42.0.0/16"];
              services.cidrBlocks = ["10.43.0.0/16"];
            };
            controlPlaneEndpoint = {
              host = sirverTailnetIp;
              port = 6443;
            };
            infrastructureRef = {
              apiGroup = "infrastructure.cluster.x-k8s.io";
              kind = "HetznerCluster";
              name = clusterName;
            };
          };
        };
        hetznerClusters.${clusterName} = {
          metadata.annotations = skipDryRun;
          spec = {
            controlPlaneEndpoint = {
              host = sirverTailnetIp;
              port = 6443;
            };
            controlPlaneLoadBalancer.enabled = false;
            controlPlaneRegions = ["nbg1"];
            hetznerSecretRef = {
              name = "hetzner";
              key.hcloudToken = "hcloud";
            };
            sshKeys.hcloud = lib.toList {name = "millionaire-capi";};
          };
        };

        # --- Worker pool ---
        hCloudMachineTemplates.cloud-worker-cpx31 = {
          metadata.annotations = skipDryRun;
          spec.template.spec = {
            type = "cpx31";
            imageName = "cloud-worker";
          };
        };
        machineDeployments.cloud-worker-cpx31 = {
          metadata.annotations =
            skipDryRun
            // {
              # Autoscaler opt-in (cluster-autoscaler clusterapi provider) +
              # scale-from-zero capacity hints (cpx31 = 4 vCPU / 8 GB).
              "cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size" = "0";
              "cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size" = "2";
              "capacity.cluster-autoscaler.kubernetes.io/cpu" = "4";
              "capacity.cluster-autoscaler.kubernetes.io/memory" = "8Gi";
            };
          spec = {
            inherit clusterName;
            replicas = 0;
            selector.matchLabels."cluster.x-k8s.io/cluster-name" = clusterName;
            template = {
              metadata.labels."cluster.x-k8s.io/cluster-name" = clusterName;
              spec = {
                inherit clusterName;
                bootstrap.dataSecretName = "cloud-worker-bootstrap";
                infrastructureRef = {
                  apiGroup = "infrastructure.cluster.x-k8s.io";
                  kind = "HCloudMachineTemplate";
                  name = "cloud-worker-cpx31";
                };
              };
            };
          };
        };
        machineHealthChecks.cloud-worker = {
          metadata.annotations = skipDryRun;
          spec = {
            inherit clusterName;
            selector.matchLabels."cluster.x-k8s.io/cluster-name" = clusterName;
            checks = {
              nodeStartupTimeoutSeconds = 900;
              unhealthyNodeConditions = [
                {
                  type = "Ready";
                  status = "False";
                  timeoutSeconds = 300;
                }
                {
                  type = "Ready";
                  status = "Unknown";
                  timeoutSeconds = 300;
                }
              ];
            };
          };
        };
      };
    };
  };
}
