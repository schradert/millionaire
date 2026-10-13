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
    portal.apps.prometheus = {
      title = "Prometheus";
      description = "Metrics collection";
    };
    gatus.endpoints.prometheus = {
      url = "https://prometheus.${config.canivete.meta.domain}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # No login of its own: oauth2-proxy, admin only (portal.defaults.observability).
    oauth2Proxy.upstreams."prometheus.${config.canivete.meta.domain}" = {
      url = "http://prometheus-kube-prometheus-prometheus.observability.svc.cluster.local:9090";
      namespace = "observability";
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
          prometheusOperator = {
            image.sha = lib.removePrefix "sha256:" pinned.images.prometheus-operator.digest;
            admissionWebhooks.deployment.image.sha = lib.removePrefix "sha256:" pinned.images.prometheus-admission-webhook.digest;
            admissionWebhooks.patch.image.sha = lib.removePrefix "sha256:" pinned.images.kube-webhook-certgen.digest;
            prometheusConfigReloader.image.sha = lib.removePrefix "sha256:" pinned.images.prometheus-operator-config-reloader.digest;
            thanosImage.sha = lib.removePrefix "sha256:" pinned.images.thanos.digest;
          };
          prometheus.prometheusSpec.image.sha = lib.removePrefix "sha256:" pinned.images.prometheus.digest;
          crds.enabled = false;
          kubelet.enabled = true;
          kubeApiServer.enabled = true;
          prometheus = {
            prometheusSpec = {
              # Select every monitor, rule and probe in all namespaces, not only
              # those labelled release=prometheus.
              serviceMonitorSelectorNilUsesHelmValues = false;
              podMonitorSelectorNilUsesHelmValues = false;
              probeSelectorNilUsesHelmValues = false;
              ruleSelectorNilUsesHelmValues = false;
              scrapeConfigSelectorNilUsesHelmValues = false;
              # Tempo's metrics-generator remote-writes service-graph and span metrics (tempo.nix).
              enableRemoteWriteReceiver = true;
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

          # Capacity-planning rules that always trip on a small, uneven cluster
          # (4-core nodes beside a 64-core one) and are not actionable.
          defaultRules.disabled = {
            KubeCPUOvercommit = true;
            KubeMemoryOvercommit = true;
          };

          # Keeps the chart's etcd rules and dashboard. Scraping is the
          # ScrapeConfig below: the chart's Service + manual Endpoints is the
          # pattern ArgoCD drops (Endpoints are in its default resource.exclusions).
          kubeEtcd.enabled = true;
          kubeEtcd.service.enabled = false;
          kubeEtcd.serviceMonitor.enabled = false;

          # The chart's CoreDNS scrape Service selects k8s-app=kube-dns; ours are
          # labelled coredns, so no coredns_* metric was ever collected.
          coreDns.service.selector."k8s-app" = "coredns";

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
              alert = "CoreDNSSlow";
              expr = ''histogram_quantile(0.99, sum by (le, instance) (rate(coredns_dns_request_duration_seconds_bucket[5m]))) > 1'';
              "for" = "10m";
              labels.severity = "warning";
              annotations.summary = "CoreDNS {{ $labels.instance }} p99 latency is above 1s";
            }
            {
              alert = "CoreDNSServfail";
              expr = ''sum by (instance) (rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m])) / sum by (instance) (rate(coredns_dns_responses_total[5m])) > 0.02'';
              "for" = "10m";
              labels.severity = "warning";
              annotations.summary = "CoreDNS {{ $labels.instance }} answers over 2% of queries with SERVFAIL";
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
            {
              # A missing allow rule shows up as retried SYNs dropped with reason "Policy denied"
              # (baseline is ~0; other drop reasons are routine IPv6/stale-IP noise).
              alert = "NetworkPolicyDrops";
              expr = ''sum(increase(cilium_drop_count_total{reason="Policy denied"}[10m])) by (instance) > 20'';
              "for" = "15m";
              labels.severity = "warning";
              annotations.summary = "Cilium on {{ $labels.instance }} keeps dropping traffic as policy-denied; find it with: hubble observe --verdict DROPPED (cilium agent pod)";
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
            name = "oauth2-proxy";
            namespace = "identity";
            port = 4180;
          };
        };
      };
    };
  };
}
