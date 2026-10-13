{
  can,
  config,
  ...
}: let
  inherit (config.canivete.meta) domain;
  faroHost = "faro.${domain}";
in {
  nixidy = {
    config,
    lib,
    pinned,
    ...
  }: let
    # Grafana's Loki datasource (grafana.nix) queries this tenant.
    tenant = "cluster";
    faroApps = config.faro.apps;
  in {
    options.faro.apps = can.attrs.submodule "Web apps that report browser telemetry (Faro) to Alloy; the name is the `app.name` they send" {
      options.origin = can.str "Origin the app is served from, allowed to POST to the receiver (CORS)" {};
    };
    # Ships every Pod's stdout/stderr to Loki: one Alloy per node tails only that node's Pods
    # through the API server (no hostPath, no root).
    # Also the cluster's OTLP gateway: any Pod sends traces to http://alloy.observability.svc:4318 (or
    # :4317 for gRPC); Alloy labels them with the sender's namespace/Pod and forwards them to Tempo.
    # No NetworkPolicy rule is needed for that: `observability` is not an enforced namespace (netpol.nix).
    # And the cluster's continuous profiler: `pyroscope.ebpf` profiles every container and the host's own daemons
    # on the node, always on, and pushes to Pyroscope (pyroscope.nix). That needs root, the host PID namespace and
    # the capabilities listed under securityContext; it stays in this one DaemonSet (not a second one) because
    # sirver is at its 110-Pod limit, so an extra Pod per node would not fit there.
    # Browser telemetry: `faro.receiver` takes Grafana Faro payloads (logs, exceptions, web vitals, events, traces) that
    # the web apps listed in `faro.apps` post to https://${faroHost}/collect; see the Faro block in the config.
    # The route has no oauth2-proxy: browsers post anonymously. What keeps it from being an open sink: CORS limited to
    # the registered origins (browsers only), the receiver's own rate limit and 1MiB payload cap, and an `app` label
    # that is only ever a registered app name or `other`. The Cilium gateway has no declarative rate limit.
    # A GET is a 405 from the receiver, which only takes POSTs: reachable through the gateway and answering.
    config.gatus.endpoints.faro = {
      url = "https://${faroHost}/collect";
      group = "internal";
      conditions = ["[STATUS] == 405"];
    };
    config.portal.apps.faro.enable = false;
    config.applications.alloy = {
      namespace = "observability";
      resources.httpRoutes.faro.spec = {
        hostnames = [faroHost];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          matches = lib.toList {
            path = {
              type = "PathPrefix";
              value = "/collect";
            };
          };
          backendRefs = lib.toList {
            name = "alloy";
            port = 12347;
          };
        };
      };
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
          # pyroscope.ebpf resolves processes through the host's /proc.
          controller.hostPID = true;
          controller.volumes.extra = [
            {
              name = "storage";
              emptyDir = {};
            }
            # pyroscope.ebpf's symbol cache.
            {
              name = "symb-cache";
              emptyDir = {};
            }
            # The tracer attaches its tracepoints through the host's tracefs.
            {
              name = "tracefs";
              hostPath.path = "/sys/kernel/tracing";
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
              {
                name = "faro";
                port = 12347;
                targetPort = 12347;
                protocol = "TCP";
              }
            ];
            # Root, because pyroscope.ebpf must be; everything else is dropped. The capabilities are the ones
            # its docs list for running without `privileged`: BPF + PERFMON (load and attach the programs),
            # SYS_PTRACE + CHECKPOINT_RESTORE + DAC_READ_SEARCH (read /proc/<pid>/ and the ELF files of any
            # container), SYS_RESOURCE (RLIMIT_MEMLOCK for the maps), SYSLOG (verifier diagnostics).
            securityContext = {
              runAsNonRoot = false;
              runAsUser = 0;
              runAsGroup = 0;
              allowPrivilegeEscalation = false;
              readOnlyRootFilesystem = true;
              capabilities = {
                drop = ["ALL"];
                add = ["BPF" "PERFMON" "SYS_PTRACE" "CHECKPOINT_RESTORE" "SYS_RESOURCE" "DAC_READ_SEARCH" "SYSLOG"];
              };
              seccompProfile.type = "RuntimeDefault";
            };
            mounts.extra = [
              {
                name = "storage";
                mountPath = "/tmp/alloy";
              }
              {
                name = "symb-cache";
                mountPath = "/tmp/symb-cache";
              }
              {
                name = "tracefs";
                mountPath = "/sys/kernel/tracing";
                readOnly = true;
              }
            ];
            extraEnv = [
              {
                name = "NODE_NAME";
                valueFrom.fieldRef.fieldPath = "spec.nodeName";
              }
              # pyroscope.ebpf parses the .eh_frame of every executable and library it meets: gigabytes of
              # short-lived garbage for a few MB live (heap profile on sirver: 2.6 GB allocated, 14 MB in use),
              # which the default GC target let grow past the container limit. Collect before that.
              {
                name = "GOMEMLIMIT";
                value = "512MiB";
              }
            ];
            resources = {
              requests = {
                cpu = "20m";
                memory = "256Mi";
              };
              # Working set measured 60-200Mi per node for the logs and traces pipelines; pyroscope.ebpf adds
              # BPF maps (about 150-200Mi of kernel memory, counted here) and the Go heap, capped by GOMEMLIMIT.
              # 512Mi OOM-killed it at start-up on octopus.
              limits.memory = "1Gi";
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
                  traces = [otelcol.processor.filter.noise.input]
                }
              }

              // Keycloak's internal transaction-commit and connection-checkout spans were ~40% of an e2e run's
              // spans (a run is ~600 spans/s for six minutes) and say nothing the SQL and HTTP spans do not.
              otelcol.processor.filter "noise" {
                error_mode = "ignore"
                traces {
                  span = [
                    `resource.attributes["service.name"] == "keycloak" and kind == SPAN_KIND_INTERNAL and (IsMatch(name, "\\.commit$") or name == "DataSource.getConnection")`,
                  ]
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

              // ---- Frontend observability (Grafana Faro) -------------------------------------------------------
              // Browsers post to https://${faroHost}/collect (the HTTPRoute above). Logs, exceptions, measurements and
              // events go to Loki as `{source="faro", app, kind}`; traces join the OTLP pipeline at the batch step
              // (no k8sattributes: the sender is a browser, not a Pod). Source maps are off.
              faro.receiver "browsers" {
                extra_log_labels = {
                  source = "faro",
                }
                server {
                  listen_address           = "0.0.0.0"
                  listen_port              = 12347
                  cors_allowed_origins     = ${builtins.toJSON (lib.mapAttrsToList (_: a: a.origin) faroApps)}
                  max_allowed_payload_size = "1MiB"
                  rate_limiting {
                    enabled    = true
                    strategy   = "global"
                    rate       = 50
                    burst_size = 100
                  }
                }
                sourcemaps {
                  download = false
                }
                output {
                  logs   = [loki.process.faro.receiver]
                  traces = [otelcol.processor.batch.default.input]
                }
              }

              // `kind` (log | exception | measurement | event) is the receiver's own. `app` comes from the payload,
              // which anyone who can reach the receiver controls: only registered names become a label value,
              // anything else is `other` (bounded label cardinality).
              loki.process "faro" {
                forward_to = [loki.write.loki.receiver]
                stage.logfmt {
                  mapping = {
                    app  = "app_name",
                    kind = "kind",
                  }
                }
                stage.labels {
                  values = {
                    app  = "",
                    kind = "",
                  }
                }
                stage.match {
                  selector = "{source=\"faro\", app!~\"${lib.concatStringsSep "|" (lib.attrNames faroApps)}\"}"
                  stage.static_labels {
                    values = {
                      app = "other",
                    }
                  }
                }
              }
              // ---- end of frontend observability ---------------------------------------------------------------

              // ---- Continuous profiling (eBPF) -> Pyroscope ----------------------------------------------------
              // Every container on this node (the Pod targets discovered above) plus the host's own daemons
              // (kubelet, containerd, ...), sampled at 19 Hz system-wide. A profile's `service_name` is
              // <namespace>/<workload>; the Pod, container and node are labels, so one workload's replicas merge
              // or split in Grafana. Python's unwinder is off: the verifier of the nodes' 7.0 kernel rejects it
              // ("BPF program is too large"), and it would stop the whole profiler from loading.
              discovery.relabel "profiled" {
                targets = discovery.kubernetes.pods.targets
                rule {
                  action        = "drop"
                  source_labels = ["__meta_kubernetes_pod_phase"]
                  regex         = "Succeeded|Failed"
                }
                rule {
                  action        = "drop"
                  source_labels = ["__meta_kubernetes_pod_container_init"]
                  regex         = "true"
                }
                // workload: the controller without the ReplicaSet hash, the CronJob timestamp or the static Pod's
                // node suffix; a Pod without controller is its own workload.
                rule {
                  source_labels = ["__meta_kubernetes_pod_name"]
                  target_label  = "workload"
                }
                rule {
                  source_labels = ["__meta_kubernetes_pod_controller_kind", "__meta_kubernetes_pod_controller_name"]
                  separator     = ";"
                  regex         = "(?:DaemonSet|StatefulSet|Job);(.+)"
                  target_label  = "workload"
                }
                rule {
                  source_labels = ["__meta_kubernetes_pod_controller_kind", "__meta_kubernetes_pod_controller_name"]
                  separator     = ";"
                  regex         = "Job;(.+)-\\d{6,}"
                  target_label  = "workload"
                }
                rule {
                  source_labels = ["__meta_kubernetes_pod_controller_kind", "__meta_kubernetes_pod_controller_name"]
                  separator     = ";"
                  regex         = "ReplicaSet;(.+)-[a-z0-9]{8,10}"
                  target_label  = "workload"
                }
                rule {
                  source_labels = ["__meta_kubernetes_pod_controller_kind", "__meta_kubernetes_pod_name"]
                  separator     = ";"
                  regex         = "Node;(.+)-" + sys.env("NODE_NAME")
                  target_label  = "workload"
                }
                rule {
                  source_labels = ["__meta_kubernetes_namespace", "workload"]
                  separator     = "/"
                  target_label  = "service_name"
                }
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
              }

              discovery.process "host" {
                refresh_interval = "60s"
                discover_config {
                  cwd         = false
                  commandline = false
                  uid         = false
                  username    = false
                }
              }

              discovery.relabel "host" {
                targets = discovery.process.host.targets
                // Processes in a container are covered by their Pod's target.
                rule {
                  action        = "drop"
                  source_labels = ["__container_id__"]
                  regex         = ".+"
                }
                // Kernel threads have no executable.
                rule {
                  action        = "drop"
                  source_labels = ["__meta_process_exe"]
                  regex         = ""
                }
                rule {
                  source_labels = ["__meta_process_exe"]
                  regex         = ".*/([^/]+)"
                  replacement   = "host/$1"
                  target_label  = "service_name"
                }
                rule {
                  target_label = "node"
                  replacement  = sys.env("NODE_NAME")
                }
              }

              pyroscope.ebpf "nodes" {
                targets        = array.concat(discovery.relabel.profiled.output, discovery.relabel.host.output)
                forward_to     = [pyroscope.write.pyroscope.receiver]
                sample_rate    = 19
                python_enabled = false
                // Only needed to correlate with traces of OBI; it would want a writable /sys/fs/bpf.
                obi_process_context_enabled = false
              }

              pyroscope.write "pyroscope" {
                endpoint {
                  url = "http://pyroscope.observability.svc.cluster.local:4040"
                }
              }
              // ---- end of continuous profiling -----------------------------------------------------------------
            '';
          };
        };
      };
    };
  };
}
