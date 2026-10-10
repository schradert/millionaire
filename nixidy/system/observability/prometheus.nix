{config, ...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: let
    chart = pinned.charts.kube-prometheus-stack;
  in {
    applications.prometheus-crds.namespace = "kube-system";
    canivete.crds.prometheus = {
      application = "prometheus-crds";
      prefix = "charts/crds/crds";
      install = true;
      src = chart;
    };
    gatus.endpoints.prometheus = {
      url = "https://prometheus.${config.canivete.meta.domain}";
      group = "internal";
    };
    applications.prometheus = {
      namespace = "observability";
      canivete.bootstrap.enable = true;
      # TODO what happens with multiple deployments???
      volsync.pvcs.prometheus = {
        title = "prometheus-prometheus-kube-prometheus-prometheus-db-prometheus-prometheus-kube-prometheus-prometheus-0";
        path = ["prometheuses" "prometheus-kube-prometheus-prometheus" "spec" "storage" "volumeClaimTemplate"];
      };
      helm.releases.prometheus = {
        chart = pinned.charts.kube-prometheus-stack;
        values = {
          crds.enabled = false;
          kubelet.enabled = true;
          kubeApiServer.enabled = true;
          prometheus = {
            prometheusSpec = {
              # Size cap below the volume, or a full disk crashloops WAL replay.
              retentionSize = "25GB";
              # alertmanager.enabled = false below (it is deployed separately), so
              # the chart emits no `alerting:` block unless pointed at it here.
              alertingEndpoints = lib.toList {
                name = "alertmanager";
                namespace = "observability";
                port = 9093;
                scheme = "http";
              };
              storageSpec.volumeClaimTemplate.spec = {
                accessModes = ["ReadWriteOnce"];
                resources.requests.storage = "30Gi";
              };
            };
          };
          prometheusOperator.admissionWebhooks.deployment.enabled = true;

          # Keeps the chart's etcd rules and dashboard. Scraping is the
          # ScrapeConfig below: the chart's Service + manual Endpoints is the
          # pattern ArgoCD drops (Endpoints are in its default resource.exclusions).
          kubeEtcd.enabled = true;
          kubeEtcd.service.enabled = false;
          kubeEtcd.serviceMonitor.enabled = false;

          # Deployed separately
          alertmanager.enabled = false;
          kubeControllerManager.enabled = false;
          kubeProxy.enabled = false;
          kubeScheduler.enabled = false;
          kubeStateMetrics.enabled = false;
          nodeExporter.enabled = false;
          grafana.enabled = false;
          grafana.forceDeployDashboards = true;
        };
      };
      # rke2 serves etcd metrics (etcd-expose-metrics) over plain HTTP on each
      # server's LAN IP only (not the tailnet IP). job matches the chart's rules.
      resources.scrapeConfigs.kube-etcd = {
        metadata.labels.release = "prometheus";
        spec = {
          jobName = "kube-etcd";
          staticConfigs = lib.toList {
            targets = map (ip: "${ip}:2381") ["192.168.50.204" "192.168.50.53" "192.168.50.105"];
          };
        };
      };
      # Selected by the Prometheus CR's ruleSelector (release: prometheus).
      resources.prometheusRules.resilience = {
        metadata.labels.release = "prometheus";
        spec.groups = lib.toList {
          name = "resilience";
          rules = [
            {
              alert = "EtcdMemberDown";
              expr = ''up{job="kube-etcd"} == 0'';
              "for" = "3m";
              labels.severity = "critical";
              annotations.summary = "etcd member {{ $labels.instance }} is not scrapable";
            }
            {
              alert = "EtcdNoLeader";
              expr = ''etcd_server_has_leader{job="kube-etcd"} == 0'';
              "for" = "1m";
              labels.severity = "critical";
              annotations.summary = "etcd member {{ $labels.instance }} has no leader";
            }
            {
              alert = "NodeNotReady";
              expr = ''kube_node_status_condition{condition="Ready",status="true"} == 0'';
              "for" = "5m";
              labels.severity = "critical";
              annotations.summary = "Node {{ $labels.node }} has been NotReady for 5m";
            }
            {
              alert = "PVCAlmostFull";
              expr = ''kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85'';
              "for" = "10m";
              labels.severity = "warning";
              annotations.summary = "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is above 85% full";
            }
            {
              alert = "ContainerRestartingFrequently";
              expr = ''increase(kube_pod_container_status_restarts_total[1h]) > 5'';
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "Container {{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }} restarted more than 5 times in 1h";
            }
          ];
        };
      };
      resources.httpRoutes.prometheus.spec = {
        hostnames = ["prometheus.${config.canivete.meta.domain}"];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "prometheus-kube-prometheus-prometheus";
            port = 9090;
          };
        };
      };
    };
  };
}
