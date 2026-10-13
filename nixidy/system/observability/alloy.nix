{
  nixidy = {pinned, ...}: let
    # Grafana's Loki datasource (grafana.nix) queries this tenant.
    tenant = "cluster";
  in {
    # Ships every Pod's stdout/stderr to Loki: one Alloy per node tails only that node's Pods
    # through the API server (no hostPath, no root).
    # Also the cluster's OTLP gateway: any Pod sends traces to http://alloy.observability.svc:4318 (or
    # :4317 for gRPC); Alloy labels them with the sender's namespace/Pod and forwards them to Tempo.
    # No NetworkPolicy rule is needed for that: `observability` is not an enforced namespace (netpol.nix).
    applications.alloy = {
      namespace = "observability";
      helm.releases.alloy = {
        chart = pinned.charts.alloy;
        values = {
          fullnameOverride = "alloy";
          crds.create = false;
          # The config checksum on the Pod template already restarts it on change.
          configReloader.enabled = false;
          image.digest = pinned.images.alloy.digest;
          serviceMonitor.enabled = true;
          # Tailing needs only Pod discovery and pods/log; the chart default also reads every Secret.
          # (An empty list in either field renders invalid YAML, hence the split.)
          rbac.rules = [
            {
              apiGroups = [""];
              resources = ["pods" "pods/log"];
              verbs = ["get" "list" "watch"];
            }
          ];
          rbac.clusterRules = [
            {
              apiGroups = [""];
              resources = ["namespaces"];
              verbs = ["get" "list" "watch"];
            }
            # otelcol.processor.k8sattributes resolves a Deployment from its ReplicaSet.
            {
              apiGroups = ["apps"];
              resources = ["replicasets"];
              verbs = ["get" "list" "watch"];
            }
          ];
          # Spans from any node reach any Alloy through the Service; prefer the local one.
          service.trafficDistribution = "PreferSameNode";
          controller.volumes.extra = [
            {
              name = "storage";
              emptyDir = {};
            }
          ];
          controller.tolerations = [
            {
              operator = "Exists";
              effect = "NoSchedule";
            }
          ];
          alloy = {
            enableReporting = false;
            extraPorts = [
              {
                name = "otlp-grpc";
                port = 4317;
                targetPort = 4317;
                protocol = "TCP";
              }
              {
                name = "otlp-http";
                port = 4318;
                targetPort = 4318;
                protocol = "TCP";
              }
            ];
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              allowPrivilegeEscalation = false;
              readOnlyRootFilesystem = true;
              capabilities.drop = ["ALL"];
              seccompProfile.type = "RuntimeDefault";
            };
            mounts.extra = [
              {
                name = "storage";
                mountPath = "/tmp/alloy";
              }
            ];
            extraEnv = [
              {
                name = "NODE_NAME";
                valueFrom.fieldRef.fieldPath = "spec.nodeName";
              }
            ];
            resources = {
              requests = {
                cpu = "20m";
                memory = "128Mi";
              };
              # Working set measured 60-200Mi per node (more where more Pods run).
              limits.memory = "512Mi";
            };
            configMap.content = ''
              discovery.kubernetes "pods" {
                role = "pod"
                selectors {
                  role  = "pod"
                  field = "spec.nodeName=" + sys.env("NODE_NAME")
                }
              }

              discovery.relabel "pods" {
                targets = discovery.kubernetes.pods.targets
                rule {
                  source_labels = ["__meta_kubernetes_namespace"]
                  target_label  = "namespace"
                }
                rule {
                  source_labels = ["__meta_kubernetes_pod_name"]
                  target_label  = "pod"
                }
                rule {
                  source_labels = ["__meta_kubernetes_pod_container_name"]
                  target_label  = "container"
                }
                rule {
                  source_labels = ["__meta_kubernetes_pod_node_name"]
                  target_label  = "node"
                }
                rule {
                  source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
                  target_label  = "app"
                }
              }

              loki.source.kubernetes "pods" {
                targets    = discovery.relabel.pods.output
                forward_to = [loki.process.pods.receiver]
              }

              // Log quality: stack traces joined, probe/scrape noise dropped, a normalised `level` label.
              // Purely additive: everything the pods log still reaches Loki, now through this block.
              loki.process "pods" {
                forward_to = [loki.write.loki.receiver]

                // Join stack traces into one entry for apps whose every entry starts with a timestamp.
                stage.match {
                  selector = "{container=~\"keycloak|ha|komga|kavita|jellyfin\"}"
                  stage.multiline {
                    firstline     = "^(?:\\[Kavita\\] )?\\[?\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2}"
                    max_wait_time = "3s"
                    max_lines     = 256
                  }
                }

                // Successful probe and scrape requests in access logs.
                stage.drop {
                  expression          = "\"(?:GET|HEAD) \\S+ HTTP/[0-9.]+\" 2\\d\\d .*kube-probe/"
                  drop_counter_reason = "probe"
                }
                stage.drop {
                  expression          = "\"(?:GET|HEAD) /(?:healthz?|readyz?|livez?|ping|-/healthy|-/ready|api/server/ping|rest/noauth/health|api/health|health/(?:live|ready|started))(?:\\?\\S*)? HTTP/[0-9.]+\" 2\\d\\d"
                  drop_counter_reason = "healthcheck"
                }
                stage.drop {
                  expression          = "\"(?:GET|HEAD) /metrics(?:\\?\\S*)? HTTP/[0-9.]+\" 2\\d\\d"
                  drop_counter_reason = "scrape"
                }

                // Level, weakest signal first: a later match overwrites an earlier one.
                // [Warning] / [error] anywhere (Serilog, nginx)
                stage.regex {
                  expression = "(?i)\\[(?P<level>verbose|debug|information|warning|error|fatal|warn|notice|crit|alert|emerg)\\]"
                }
                // A level word after the timestamp or at the start: INFO, [WRN], WARNING:
                stage.regex {
                  expression = "(?i)^(?:[^a-z]|[TZ]){0,60}?\\[?(?P<level>trace|debug|info|information|notice|warn|warning|error|err|fatal|critical|crit|verbose|vrb|dbg|inf|wrn|ftl)\\]?[\\s:]"
                }
                // Monolog (PHP): production.ERROR:
                stage.regex {
                  expression = "\\.(?P<level>DEBUG|INFO|NOTICE|WARNING|ERROR|CRITICAL|ALERT|EMERGENCY): "
                }
                // klog / glog: E1013 03:50:12
                stage.regex {
                  expression = "^(?P<level>[IWEF])\\d{4} \\d{2}:\\d{2}:\\d{2}"
                }
                // level=warn, "level":"warn", severity: ERROR
                stage.regex {
                  expression = "(?i)(?:^|[\\s,{;(])\"?(?:level|lvl|severity|log_level|loglevel)\"?\\s*[=:]\\s*\"?(?P<level>trace|debug|info|information|notice|warn|warning|error|err|fatal|critical|crit|panic|verbose)"
                }
                // Fold synonyms into debug | info | warn | error (a line with no recognised level gets no label).
                stage.replace {
                  source     = "level"
                  expression = "(?i)^(warning|wrn|w)$"
                  replace    = "warn"
                }
                stage.replace {
                  source     = "level"
                  expression = "(?i)^(err|fatal|ftl|crit|critical|alert|emerg|emergency|panic|severe|e|f)$"
                  replace    = "error"
                }
                stage.replace {
                  source     = "level"
                  expression = "(?i)^(information|inf|notice|i)$"
                  replace    = "info"
                }
                stage.replace {
                  source     = "level"
                  expression = "(?i)^(trace|dbg|verbose|vrb|fine)$"
                  replace    = "debug"
                }
                stage.replace {
                  source     = "level"
                  expression = "(?i)^(debug)$"
                  replace    = "debug"
                }
                stage.replace {
                  source     = "level"
                  expression = "(?i)^(info)$"
                  replace    = "info"
                }
                stage.replace {
                  source     = "level"
                  expression = "(?i)^(warn)$"
                  replace    = "warn"
                }
                stage.replace {
                  source     = "level"
                  expression = "(?i)^(error)$"
                  replace    = "error"
                }
                stage.labels {
                  values = {
                    level = "",
                  }
                }
              }

              loki.write "loki" {
                endpoint {
                  url       = "http://loki.observability.svc.cluster.local:3100/loki/api/v1/push"
                  tenant_id = "${tenant}"
                }
              }

              otelcol.receiver.otlp "default" {
                grpc {
                  endpoint = "0.0.0.0:4317"
                }
                http {
                  endpoint = "0.0.0.0:4318"
                }
                output {
                  traces = [otelcol.processor.k8sattributes.default.input]
                }
              }

              // The sender is found by the span's k8s.pod.ip attribute, else by the connection's source address
              // (Cilium keeps Pod IPs for in-cluster traffic).
              otelcol.processor.k8sattributes "default" {
                auth_type = "serviceAccount"
                pod_association {
                  source {
                    from = "resource_attribute"
                    name = "k8s.pod.ip"
                  }
                }
                pod_association {
                  source {
                    from = "connection"
                  }
                }
                extract {
                  metadata = [
                    "k8s.namespace.name",
                    "k8s.pod.name",
                    "k8s.node.name",
                    "k8s.deployment.name",
                    "k8s.statefulset.name",
                    "k8s.daemonset.name",
                    "k8s.job.name",
                    "k8s.cronjob.name",
                  ]
                }
                output {
                  traces = [otelcol.processor.batch.default.input]
                }
              }

              otelcol.processor.batch "default" {
                output {
                  traces = [otelcol.exporter.otlp.tempo.input]
                }
              }

              otelcol.exporter.otlp "tempo" {
                client {
                  endpoint = "tempo.observability.svc.cluster.local:4317"
                  tls {
                    insecure = true
                  }
                }
              }
            '';
          };
        };
      };
    };
  };
}
