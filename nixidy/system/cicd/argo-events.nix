{...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.argo-events-crds.namespace = "kube-system";
    canivete.crds.argo-events = {
      application = "argo-events-crds";
      install = true;
      prefix = "manifests/base/crds";
      match = "argoproj\\.io_.*\\.yaml$"; # only the real CRD files, not kustomization.yaml
      src = pinned.argo-events;
    };

    applications.argo-events = {
      # Forgejo webhook secret; set the same value on the Forgejo webhook.
      generatedSecrets.forgejo-webhook-secret.key = "secret";
      namespace = "cicd";
      helm.releases.argo-events = {
        chart = pinned.charts.argo-events;
        values = {
          global.image = with pinned.images.argo-events; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          crds.install = false;
          controller.metrics.enabled = true;
          controller.metrics.serviceMonitor.enabled = true;
        };
      };
      resources = {
        eventBus.default.spec.jetstream = {
          version = "2.10.10";
          replicas = 1;
          persistence = {
            storageClassName = "ceph-block";
            accessMode = "ReadWriteOnce";
            volumeSize = "5Gi";
          };
          # The default stream config asks for 3 replicas, which a single-node bus rejects.
          streamConfig = ''
            maxMsgs: 1000000
            maxAge: 72h
            replicas: 1
            duplicates: 300s
          '';
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

        # EventSource: listens for Forgejo push webhooks
        eventSources.forgejo.spec.webhook.push = {
          port = "12000";
          endpoint = "/push";
          method = "POST";
        };

        # Image publishing. The cluster is tailnet-only, so GitHub can't push a
        # webhook in; instead a calendar EventSource ticks every 10 minutes and
        # the image-publish workflow itself resolves github main HEAD, skips if
        # that sha was already published, and otherwise builds+pushes whichever
        # images.nix tags are missing from Harbor.
        eventSources.image-poll.spec.calendar.main = {
          schedule = "*/10 * * * *";
          timezone = "UTC";
        };
        sensors.image-publish.spec = {
          template.serviceAccountName = "argo-events-sensor";
          dependencies = lib.toList {
            name = "tick";
            eventSourceName = "image-poll";
            eventName = "main";
          };
          triggers = lib.toList {
            template = {
              name = "image-publish";
              argoWorkflow = {
                operation = "submit";
                source.resource = {
                  apiVersion = "argoproj.io/v1alpha1";
                  kind = "Workflow";
                  metadata.generateName = "image-publish-";
                  spec.workflowTemplateRef.name = "image-publish";
                };
              };
            };
          };
        };

        # Sensor: triggers build-and-push workflow on push to main
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
              name = "build-and-push";
              argoWorkflow = {
                operation = "submit";
                source.resource = {
                  apiVersion = "argoproj.io/v1alpha1";
                  kind = "Workflow";
                  metadata.generateName = "build-push-";
                  spec = {
                    workflowTemplateRef.name = "build-and-push";
                    arguments.parameters = [
                      {name = "repo-url";}
                      {name = "revision";}
                      {
                        name = "image-name";
                        value = "sveltekit-demo";
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
                ];
              };
            };
          };
        };
      };
    };
  };
}
