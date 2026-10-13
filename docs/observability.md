# Observability coverage

Metrics: Prometheus (kube-prometheus-stack) selects every ServiceMonitor, PodMonitor, Probe and ScrapeConfig in all namespaces.
Logs: one Alloy per node tails every Pod's stdout/stderr into Loki (tenant `cluster`). Dashboards: Grafana's sidecar loads every
ConfigMap labelled `grafana_dashboard` from any namespace.

Audit of 2026-10-13 (`kubectl -n cicd get applications`, 136 apps).

| | before | after |
|---|---|---|
| Apps with a scrape | 31 of 134 | 58 of 136 |
| Prometheus targets (all up) | 114 | 178 |
| ServiceMonitors / PodMonitors | 37 / 25 | 57 / 36 |
| Dashboards in Grafana | 34 | 51 |

"After" includes Tempo and Mimir, added by other work. A CNPG `Cluster` brings its own PodMonitor (`monitoring.enablePodMonitor`,
default on, nixidy/system/storage/postgres.nix), so every database is scraped; the table says "CNPG database only" where that is all an app has.

## Adding a scrape

1. Turn the native metrics on (env var, flag or config), exposing a named Service/container port.
2. app-template apps: `service.<name>.ports.metrics.port` plus `serviceMonitor.<name> = {serviceName; endpoints = [...]}`.
   Chart apps: the chart's own monitor is often capability-gated and renders nothing under `helm template`; write a
   `resources.podMonitors` / `serviceMonitors` entry instead, and select only labels the rendered Service has (nixidy strips
   `helm.sh/chart` and `app.kubernetes.io/version`).
3. Namespaces with `netpol.namespaces.<ns>.enforce` already admit Prometheus; an app with its own CiliumNetworkPolicy needs a rule for it (Navidrome has one).
4. Authenticated endpoints: `authorization.credentials` (Secret ref) in the endpoint, or the pod's service-account token over TLS (Dragonfly operator, VolSync).
5. Check `up` in Prometheus (`/targets`), then add a dashboard under nixidy/system/observability/dashboards/ (one ConfigMap per JSON, see dashboards.nix).

## Apps

| App | Metrics | Gap |
|---|---|---|
| actual | none | no metrics endpoint upstream |
| alertmanager | PodMonitor |  |
| alloy | ServiceMonitor |  |
| android | none | static nginx; no stub_status exporter |
| apps | n/a | app-of-apps (ArgoCD Applications); state comes from kube-state-metrics custom resource metrics |
| archive-ingest | none | rsyncd; no metrics |
| argo | ServiceMonitor (controller) + PodMonitor (server, repo-server, applicationset, notifications) |  |
| argo-events | ServiceMonitor (controller) + PodMonitor (NATS bus, EventSources, Sensors) |  |
| argo-events-crds | CRDs only | none needed |
| argo-rollouts | ServiceMonitor |  |
| argo-rollouts-crds | CRDs only | none needed |
| argo-workflows | PodMonitor (controller) + CNPG |  |
| argo-workflows-crds | CRDs only | none needed |
| atuin | ServiceMonitor + CNPG |  |
| audiobookshelf | none | no metrics endpoint upstream |
| autobrr | ServiceMonitor (AUTOBRR__METRICS_*) + CNPG |  |
| backup-verify | n/a | CronJob; kube-state-metrics job series drive the alerts |
| baikal | none | no metrics endpoint upstream |
| bazarr | none | exportarr needs Bazarr's API key, which only lives in its config.yaml (no env or flag to set it, so it cannot be managed declaratively) |
| bifrost | ServiceMonitor (telemetry plugin) |  |
| bulwark | none | webmail UI; no metrics |
| cert-manager | ServiceMonitor |  |
| cert-manager-certificates | n/a | Certificate CRs; cert-manager's own metrics cover expiry |
| cert-manager-crds | CRDs only | none needed |
| chirpstack | ServiceMonitor ([monitoring] :9100) + CNPG + Dragonfly |  |
| cilium | ServiceMonitors: agent, envoy, operator, hubble-relay |  |
| cilium-crds | CRDs only | none needed |
| clickhouse | ServiceMonitor (operator) |  |
| clickhouse-crds | CRDs only | none needed |
| cloudflared | ServiceMonitor |  |
| contextforge | CNPG database only | native /metrics/prometheus exists but needs a JWT bearer; no declarative token. CNPG metrics are scraped |
| coredns | via prometheus app: kube-prometheus-coredns ServiceMonitor |  |
| dashy | none | static app; no metrics |
| descheduler | ServiceMonitor |  |
| dragonflydb | ServiceMonitor (operator) + PodMonitor (every Dragonfly instance, admin port) |  |
| dragonflydb-crds | CRDs only | none needed |
| dvd-webdav | none | WebDAV server; no metrics |
| e2e | n/a | test Jobs |
| excalidraw | none | static app; no metrics |
| external-dns | ServiceMonitor |  |
| external-dns-crds | CRDs only | none needed |
| external-dns-internal | ServiceMonitor |  |
| external-secrets | PodMonitor (controller, cert-controller, webhook) |  |
| external-secrets-crds | CRDs only | none needed |
| firefly | CNPG database only | no metrics endpoint upstream. CNPG metrics are scraped |
| flaresolverr | ServiceMonitor (PROMETHEUS_ENABLED) |  |
| forgejo | ServiceMonitor ([metrics] ENABLED) + CNPG |  |
| frigate | ServiceMonitor (/api/metrics) |  |
| games-webdav | none | WebDAV server; no metrics |
| gateway-crds | CRDs only | none needed |
| gatus | ServiceMonitor + CNPG |  |
| generic-device-plugin | none | no named metrics port; not scraped |
| govee2mqtt | none | no metrics endpoint |
| grafana | ServiceMonitor |  |
| ha | none | prometheus integration is not enabled: /api/prometheus needs a long-lived token (a manual secret) or `requires_auth: false`, which would publish every entity state to anything that can reach :8123. CNPG metrics are scraped |
| harbor | ServiceMonitor + CNPG + Dragonfly |  |
| homarr | CNPG database only | no metrics endpoint. CNPG metrics are scraped |
| homepage | none | no metrics endpoint upstream |
| immich | ServiceMonitor (IMMICH_TELEMETRY_INCLUDE: API :8081, workers :8082) + CNPG + Dragonfly |  |
| jellyfin | ServiceMonitor (init container sets EnableMetrics in system.xml) |  |
| jitsi | ServiceMonitor (jvb.metrics exporter sidecar) |  |
| k8tz | none | admission webhook; no metrics |
| kavita | none | no metrics endpoint upstream |
| keycloak | ServiceMonitor (management :9000) + CNPG |  |
| keycloak-operator | PodMonitor |  |
| keycloak-operator-crds | CRDs only | none needed |
| komga | none | Spring actuator /actuator/prometheus exists but needs admin basic-auth credentials (no declarative credential); returns the SPA shell otherwise |
| kosync | none | korrosync; no metrics |
| kube-state-metrics | ServiceMonitor |  |
| kubelet-csr-approver | ServiceMonitor |  |
| librechat | none | no metrics endpoint upstream (MongoDB sidecar has no exporter) |
| lidarr | ServiceMonitor (exportarr sidecar) + CNPG |  |
| logseq | none | static app; no metrics |
| loki | PodMonitor (store, canary, memcached exporters) |  |
| mainsail | none | static UI; printer metrics come from prometheus-klipper-exporter |
| maintainerr | none | no metrics endpoint upstream |
| maloja | none | no metrics endpoint upstream |
| mealie | CNPG database only | no metrics endpoint upstream. CNPG metrics are scraped |
| media-e2e | n/a | test Jobs |
| media-storage | n/a | PVCs |
| mimir | ServiceMonitor/PodMonitor (added by the Mimir work) |  |
| miniflux | ServiceMonitor (METRICS_COLLECTOR) + CNPG |  |
| mobileraker-companion | none | no metrics endpoint |
| mooncord | none | no metrics endpoint |
| mosquitto | ServiceMonitor (sapcc exporter sidecar over $SYS) |  |
| multi-scrobbler | none | no metrics endpoint upstream |
| multus | none | CNI daemonset; no metrics |
| multus-crds | CRDs only | none needed |
| music-assistant | none | no metrics endpoint upstream |
| namespaces | n/a | Namespaces |
| navidrome | ServiceMonitor (ND_PROMETHEUS_ENABLED); its CiliumNetworkPolicy admits Prometheus |  |
| netpol | n/a | CiliumClusterwideNetworkPolicies; Hubble metrics cover verdicts |
| node-exporter | ServiceMonitor |  |
| nvidia-gpu-operator | ServiceMonitors (gpu-operator, DCGM exporter) + PodMonitor (NFD) |  |
| nvidia-gpu-operator-crds | CRDs only | none needed |
| oauth2-proxy | ServiceMonitor (--metrics-address :44180) + Dragonfly |  |
| obico | CNPG database only | no metrics endpoint. CNPG metrics are scraped |
| openclaw | none | no metrics endpoint (ai-sandbox) |
| openviking | none | no metrics endpoint |
| org-bridge | none | own service, no metrics yet |
| org-storage | n/a | PVCs |
| owncast | none | no Prometheus endpoint upstream |
| postgres | PodMonitor (CNPG operator); instances via each Cluster's PodMonitor |  |
| postgres-crds | CRDs only | none needed |
| prometheus | ServiceMonitors (operator, prometheus, kubelet/cAdvisor, apiserver, CoreDNS) + ScrapeConfig (etcd) |  |
| prometheus-crds | CRDs only | none needed |
| prometheus-klipper-exporter | ServiceMonitor (/probe, printer offline) |  |
| promptfoo | none | no metrics endpoint |
| prowlarr | ServiceMonitor (exportarr sidecar) + CNPG |  |
| qbittorrent | none | scaled to 0 (no VPN credentials). When enabled it needs an exporter sidecar and gluetun's FIREWALL_INPUT_PORTS opened for it; WebUI auth is off on localhost so no secret is needed |
| radarr | ServiceMonitor (exportarr sidecar) + CNPG |  |
| rclone | none | `--rc-enable-metrics` is not set (rclone rc is the only place it serves them) |
| recyclarr | n/a | CronJob |
| reloader | PodMonitor |  |
| rook-ceph | via operator-managed ServiceMonitors (rook-ceph-mgr, rook-ceph-exporter) and csi |  |
| ryot | CNPG database only | no metrics endpoint upstream. CNPG metrics are scraped |
| seerr | none | no metrics endpoint upstream |
| shoko | none | no metrics endpoint upstream |
| siyuan | none | no metrics endpoint upstream |
| smartctl-exporter | ServiceMonitor |  |
| sonarr | ServiceMonitor (exportarr sidecar) + CNPG |  |
| spoolman | ServiceMonitor (SPOOLMAN_METRICS_ENABLED) |  |
| stalwart | ServiceMonitor |  |
| sure | CNPG database only | no metrics endpoint upstream (Rails). CNPG and Dragonfly metrics are scraped |
| sveltekit-demo | none | demo app; no metrics |
| sync-storage | n/a | PVCs |
| syncthing | ServiceMonitor (/metrics, GUI API key as bearer) |  |
| tempo | ServiceMonitor |  |
| toolhive | PodMonitor (operator) |  |
| toolhive-crds | CRDs only | none needed |
| volsync | ServiceMonitor (TLS + token, :8443) |  |
| volsync-crds | CRDs only | none needed |
| webdav | none | WebDAV server; no metrics |
| windmill | PodMonitor (workers) + CNPG |  |
| zigbee2mqtt | none | no Prometheus endpoint (device state flows over MQTT; Mosquitto is scraped) |
| zwave-js-ui | none | no Prometheus endpoint upstream |

## Outside the cluster (hyena)

Read-only inspection; hyena is not changed by this work.

| Service | State |
|---|---|
| headscale | `metrics_listen_addr` is not listening (nothing on :9090); needs a static/hyena.nix change and a redeploy |
| ntfy | `/metrics` returns the web app, so `enable-metrics` is off; a scrape over the tailnet (:2586 is reachable from pods) works once it is on |
| AdGuard Home | no native Prometheus endpoint (:3000/metrics is the login-gated UI); needs an exporter |
| Gatus (hyena) | `/metrics` is 404; `metrics: true` in its config exposes it on :8081 |
| node, tailscaled | no exporter |

## Cluster components not scraped

kube-scheduler, kube-controller-manager and kube-proxy (disabled in prometheus.nix), the Rook operator
(no named metrics port), Multus, k8tz, generic-device-plugin, Hubble UI.

## Logs

Every container's stdout/stderr is shipped; nothing found that logs only to files. Of 199 running containers, 24 had no line in
24h and all of them print to stdout (they are quiet: dashy, homepage, webdav, cert-manager, Alertmanager, ...). Jibri (recordings, parked at 0
replicas) is the one candidate: upstream writes its logs under /var/log/jitsi (not checked here, it is not running).

nixidy/system/observability/alloy.nix, `loki.process "pods"`:

- `level` label (`debug|info|warn|error`) from JSON/logfmt keys (`level`, `severity`), level words after the timestamp (`INFO`, `[WRN]`,
  `WARNING`), Serilog, monolog (`production.ERROR`) and klog; lines with none get no label.
- Stack traces joined into one entry for Keycloak, Home Assistant, Komga, Kavita and Jellyfin (every entry starts with a timestamp, so
  a non-timestamp line is a continuation). Add a container to the selector only after checking that.
- Dropped: successful kube-probe requests, health-check paths and `/metrics` in access logs (counted in `loki_process_dropped_lines_total` by reason).

## Dashboards

Already provisioned by charts: Kubernetes compute/networking/kubelet/API server/etcd/CoreDNS/persistent volumes, Prometheus, Grafana,
Cilium and Hubble, CloudNativePG, ClickHouse, Frigate, Windmill.

nixidy/system/observability/dashboards/: Node Exporter Full, Ceph cluster and pools, ArgoCD operational, cert-manager, Alertmanager,
External Secrets, exportarr, and ones built from the metrics the apps serve: Scrape health, Logs explorer, Keycloak, Immich, Jellyfin,
Syncthing, Forgejo, Navidrome, VolSync. The downloaded ones come from grafana.com (1860, 2842, 5342, 19993, 20842, 9578), the exportarr
and external-secrets repos, with their datasource inputs pinned to the `prometheus` / `loki` uids from grafana.nix.
