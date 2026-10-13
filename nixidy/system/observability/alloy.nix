{
  nixidy = {pinned, ...}: let
    # Grafana's Loki datasource (grafana.nix) queries this tenant.
    tenant = "cluster";
  in {
    # Ships every Pod's stdout/stderr to Loki: one Alloy per node tails only that node's Pods
    # through the API server (no hostPath, no root).
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
          ];
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
                memory = "64Mi";
              };
              limits.memory = "256Mi";
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
                forward_to = [loki.write.loki.receiver]
              }

              loki.write "loki" {
                endpoint {
                  url       = "http://loki.observability.svc.cluster.local:3100/loki/api/v1/push"
                  tenant_id = "${tenant}"
                }
              }
            '';
          };
        };
      };
    };
  };
}
