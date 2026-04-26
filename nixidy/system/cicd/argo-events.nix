{...}: {
  nixidy = {lib, pkgs, ...}: {
    applications.argo-events-crds.namespace = "kube-system";
    canivete.crds.argo-events = {
      application = "argo-events-crds";
      install = true;
      prefix = "manifests/base/crds";
      src = pkgs.fetchFromGitHub {
        owner = "argoproj";
        repo = "argo-events";
        rev = "v1.9.10";
        hash = "sha256-C0FDilzSjY7OMtqQV/mudT+Ojg4+w2FL6IKVgs0dNQ4=";
      };
    };

    applications.argo-events = {
      namespace = "cicd";
      helm.releases.argo-events = {
        chart = lib.helm.downloadHelmChart {
          chart = "argo-events";
          version = "2.4.21";
          repo = "https://argoproj.github.io/argo-helm";
          chartHash = "sha256-I2seJPvPXti08DSnWFbjH9wj4ysx8zYLSN4D8CU4aHQ=";
        };
        values = {
          crds.install = false;
          controller.metrics.enabled = true;
          controller.metrics.serviceMonitor.enabled = true;
        };
      };
      resources = {
        eventBus.default.spec.jetstream = {
          version = "2.10.24";
          replicas = 1;
          persistence = {
            storageClassName = "ceph-block";
            accessMode = "ReadWriteOnce";
            volumeSize = "5Gi";
          };
        };

        # Sensor ServiceAccount + RBAC (needs to create Workflows)
        serviceAccounts.argo-events-sensor = {};
        roles.argo-events-sensor.rules = [
          {
            apiGroups = ["argoproj.io"];
            resources = ["workflows"];
            verbs = ["create"];
          }
          {
            apiGroups = ["argoproj.io"];
            resources = ["workflowtemplates"];
            verbs = ["get"];
          }
        ];
        roleBindings.argo-events-sensor = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "argo-events-sensor";
          };
          subjects = lib.toList {
            kind = "ServiceAccount";
            name = "argo-events-sensor";
            namespace = "cicd";
          };
        };

        # Forgejo webhook secret
        externalSecrets.forgejo-webhook-secret.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          data = lib.toList {
            secretKey = "secret";
            remoteRef.key = "forgejo/webhook/secret";
          };
        };

        # EventSource: listens for Forgejo push webhooks
        eventSources.forgejo.spec.webhook.push = {
          port = "12000";
          endpoint = "/push";
          method = "POST";
        };

        # Sensor: triggers build-and-deploy workflow on push to main
        sensors.forgejo-push.spec = {
          template.serviceAccountName = "argo-events-sensor";
          dependencies = lib.toList {
            name = "push";
            eventSourceName = "forgejo";
            eventName = "push";
            filters.data = lib.toList {
              path = "body.ref";
              type = "string";
              value = ["refs/heads/main"];
            };
          };
          triggers = lib.toList {
            template = {
              name = "build-and-deploy";
              argoWorkflow = {
                operation = "submit";
                source.resource = {
                  apiVersion = "argoproj.io/v1alpha1";
                  kind = "Workflow";
                  metadata.generateName = "build-deploy-";
                  spec = {
                    workflowTemplateRef.name = "build-and-deploy";
                    arguments.parameters = [
                      {name = "repo-url";}
                      {name = "revision";}
                      {
                        name = "image-name";
                        value = "sveltekit-demo";
                      }
                      {name = "image-tag";}
                      {
                        name = "rollout-name";
                        value = "sveltekit-demo";
                      }
                      {
                        name = "rollout-namespace";
                        value = "development";
                      }
                    ];
                  };
                };
                parameters = [
                  {
                    src = {
                      dependencyName = "push";
                      dataKey = "body.repository.clone_url";
                    };
                    dest = "spec.arguments.parameters.0.value";
                  }
                  {
                    src = {
                      dependencyName = "push";
                      dataKey = "body.after";
                    };
                    dest = "spec.arguments.parameters.1.value";
                  }
                  {
                    src = {
                      dependencyName = "push";
                      dataKey = "body.after";
                    };
                    dest = "spec.arguments.parameters.3.value";
                  }
                ];
              };
            };
          };
        };
      };
    };
  };
}
