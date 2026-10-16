# Node-level remediation: medik8s Node Health Check decides a node is unhealthy, Self Node Remediation fences it
# (the node reboots itself, then its pods are force-moved with the out-of-service taint so RBD volumes detach).
# Neither project ships a chart (OLM only), so both are their upstream `config/default` kustomizations. Only the
# worker agents are ever remediated: control-plane/etcd nodes and desktops are outside the selector and run no
# SNR agent. NHC starts paused (docs/node-standard.md "Node remediation").
{...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    ns = "medik8s";
    image = pin: with pin; "${repository}:${tag}@${digest}";
    # The CRDs live in medik8s-crds, which can sync after these.
    crWave = {
      "argocd.argoproj.io/sync-wave" = "1";
      "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true";
    };
    # Both managers read tls.crt/tls.key from controller-runtime's default dir; upstream leaves the cert to OLM.
    # Webhooks fail open so deleting the CRs (ArgoCD prune) can never block on a webhook that is already gone.
    webhookCert = prefix: {
      issuers."${prefix}-selfsigned".spec.selfSigned = {};
      certificates."${prefix}-serving-cert".spec = {
        secretName = "${prefix}-webhook-server-cert";
        dnsNames = map (suffix: "${prefix}-webhook-service.${ns}.${suffix}") ["svc" "svc.cluster.local"];
        issuerRef = {
          kind = "Issuer";
          name = "${prefix}-selfsigned";
        };
      };
    };
    managerCert = prefix: {
      volumes.cert.secret.secretName = "${prefix}-webhook-server-cert";
      containers.manager.volumeMounts."/tmp/k8s-webhook-server/serving-certs" = {
        name = "cert";
        readOnly = true;
      };
    };
    injectCa = prefix: {metadata.annotations."cert-manager.io/inject-ca-from" = "${ns}/${prefix}-serving-cert";};
    failOpen = names: {webhooks = lib.genAttrs names (_: {failurePolicy = lib.mkForce "Ignore";});};
    dropOwnedKinds = lib.filter (obj: !(lib.elem obj.kind ["Namespace" "CustomResourceDefinition"]));
    agents = [
      {
        key = "node-role.kubernetes.io/control-plane";
        operator = "DoesNotExist";
      }
      {
        key = "node.trdos.me/class";
        operator = "NotIn";
        values = ["desktop"];
      }
    ];
    template = {
      kind = "SelfNodeRemediationTemplate";
      apiVersion = "self-node-remediation.medik8s.io/v1alpha1";
      name = "out-of-service";
      namespace = ns;
    };
    metricsEndpoint = lib.toList {
      port = "https";
      scheme = "https";
      path = "/metrics";
      interval = "1m";
      bearerTokenFile = "/var/run/secrets/kubernetes.io/serviceaccount/token";
      tlsConfig.insecureSkipVerify = true;
    };
  in {
    applications.namespaces.resources.namespaces.${ns} = {};

    applications.medik8s-crds.namespace = "kube-system";
    canivete.crds = lib.genAttrs ["node-healthcheck-operator" "self-node-remediation"] (name: {
      application = "medik8s-crds";
      install = true;
      prefix = "config/crd/bases";
      src = pinned.${name};
    });

    applications.node-healthcheck-operator = {
      namespace = ns;
      kustomize.applications.node-healthcheck-operator = {
        kustomization = {
          src = pinned.node-healthcheck-operator;
          path = "config/default";
        };
        transformer = dropOwnedKinds;
      };
      resources = lib.mkMerge [
        (webhookCert "node-healthcheck")
        {
          deployments.node-healthcheck-controller-manager.spec.template.spec = lib.mkMerge [
            (managerCert "node-healthcheck")
            {containers.manager.image = lib.mkForce (image pinned.images.node-healthcheck-operator);}
          ];
          validatingWebhookConfigurations.node-healthcheck-validating-webhook-configuration = lib.mkMerge [
            (injectCa "node-healthcheck")
            (failOpen ["vnodehealthcheck.kb.io"])
          ];
          serviceMonitors.node-healthcheck.spec = {
            selector.matchLabels."app.kubernetes.io/name" = "node-healthcheck-operator";
            endpoints = metricsEndpoint;
          };
          nodeHealthChecks.agents = {
            metadata.annotations = crWave;
            spec = {
              # Agents only. Control-plane nodes are never remediated (sirver's disk is failing and octopus hangs on a
              # graceful reboot: a reboot there is an etcd and OSD event to plan, not to automate). Desktops (falcon,
              # axolotl) sleep and reboot at the user's will, which would read as unhealthy.
              selector.matchExpressions = agents;
              # Two nodes are selected and one must stay healthy, so at most one is remediated at a time.
              minHealthy = 1;
              # octopus' etcd flaps once left a kubelet Unknown for 4 minutes; 15 is well above that.
              unhealthyConditions = map (status: {
                type = "Ready";
                inherit status;
                duration = "15m";
              }) ["False" "Unknown"];
              remediationTemplate = template;
              pauseRequests = ["staged: unpause after the reboot drill (docs/node-standard.md)"];
            };
          };
          prometheusRules.node-healthcheck = {
            metadata.labels.release = "prometheus";
            spec.groups = lib.toList {
              name = "node-healthcheck";
              rules = [
                {
                  alert = "NodeRemediationInProgress";
                  expr = "nodehealthcheck_ongoing_remediation == 1";
                  "for" = "1m";
                  labels.severity = "warning";
                  annotations = {
                    summary = "Node remediation {{ $labels.name }} ({{ $labels.remediation }}) is in progress";
                    description = "A node stayed NotReady past the NodeHealthCheck threshold and is being rebooted. kubectl get nodehealthcheck,selfnoderemediation -A";
                  };
                }
                {
                  alert = "NodeRemediationStuck";
                  expr = "increase(nodehealthcheck_old_remediation_cr[1h]) > 0";
                  labels.severity = "warning";
                  annotations = {
                    summary = "A remediation of NodeHealthCheck {{ $labels.name }} has been pending for a long time";
                    description = "The remediation CR is not being picked up or finished. kubectl -n ${ns} get selfnoderemediation; pause with spec.pauseRequests.";
                  };
                }
              ];
            };
          };
        }
      ];
    };

    applications.self-node-remediation = {
      namespace = ns;
      kustomize.applications.self-node-remediation = {
        kustomization = {
          src = pinned.self-node-remediation;
          path = "config/default";
        };
        transformer = dropOwnedKinds;
      };
      resources = lib.mkMerge [
        (webhookCert "self-node-remediation")
        {
          deployments.self-node-remediation-controller-manager.spec.template.spec = lib.mkMerge [
            (managerCert "self-node-remediation")
            {
              # The same image is the agent DaemonSet the operator creates.
              containers.manager = {
                image = lib.mkForce (image pinned.images.self-node-remediation-operator);
                env.SELF_NODE_REMEDIATION_IMAGE.value = lib.mkForce (image pinned.images.self-node-remediation-operator);
              };
            }
          ];
          mutatingWebhookConfigurations.self-node-remediation-mutating-webhook-configuration = lib.mkMerge [
            (injectCa "self-node-remediation")
            (failOpen ["mselfnoderemediationtemplate.kb.io"])
          ];
          validatingWebhookConfigurations.self-node-remediation-validating-webhook-configuration = lib.mkMerge [
            (injectCa "self-node-remediation")
            (failOpen ["vselfnoderemediationconfig.kb.io" "vselfnoderemediationtemplate.kb.io"])
          ];
          serviceMonitors.self-node-remediation.spec = {
            selector.matchLabels.control-plane = "controller-manager";
            endpoints = metricsEndpoint;
          };
          # The operator creates a default config when absent and adopts one of this name.
          selfNodeRemediationConfigs.self-node-remediation-config = {
            metadata.annotations = crWave;
            spec.customDsNodeSelectorRequirements = agents;
          };
          selfNodeRemediationTemplates.${template.name} = {
            metadata.annotations = crWave;
            spec.template.spec.remediationStrategy = "OutOfServiceTaint";
          };
        }
      ];
    };
  };
}
