# Network policy

Cilium policy for the cluster: what is enforced, how a namespace is vetted before it is enforced, and the egress design (not
implemented). The module is `nixidy/system/network/netpol.nix`, the per-namespace entries are `nixidy.netpol.namespaces.<ns>` in
`nixidy/apps/default.nix`, and `README.md` ("Network policy") says how to add a rule for a new app.

## Ingress

Every namespace with listening workloads but `kube-system` is default-deny for ingress (`e2e` and `backup-verify` only run CronJobs that call out). `netpol.namespaces.<ns>.enforce` renders one
CiliumClusterwideNetworkPolicy (`nixidy/generated/prod/netpol`) that selects every pod of the namespace and allows only the
baseline (kubelet probes and webhooks from `host`/`remote-node`/`kube-apiserver`, the Gateway's envoy as `ingress`, Prometheus and
Gatus, oauth2-proxy on its upstream ports) plus the entry's `extraIngress`. Egress is not restricted anywhere yet (see "Egress").

### Host-network workloads are not filtered

The Cilium host firewall is off (`enable-host-firewall: "false"`; `cilium-dbg status` says `Host firewall: Disabled`), so a pod with
`hostNetwork: true` has no Cilium endpoint (no CiliumEndpoint object, no row in `cilium-dbg endpoint list`) and no namespace policy
selects it. Traffic to it is traffic to the node's address: policy never drops it, and traffic from it reaches a pod as `host` (same
node) or `remote-node` (other node; `kube-apiserver` as well on the control-plane nodes). This is why the baseline covers every
host-network caller of a pod-network workload, and why no rule exists for traffic that goes to a host-network workload.

- `storage`: every Ceph daemon (mons, mgr, mds, osds, rgw, exporter, crash collectors; `network.provider = "host"` in
  `nixidy/system/storage/rook-ceph.nix`) and both CSI node plugins are host-network. The policy cannot break Ceph traffic: a CephFS
  or RBD mount, a mon or OSD connection, an S3 call to rgw (Mimir, Pyroscope, Argo Workflows, `rados.<domain>`), the Ceph dashboard
  route and Prometheus scraping the mgr and the exporter all go to node addresses.
- `kube-system`: Cilium (agent, operator, Envoy, which also serves the Gateway), etcd, the apiserver, the controller manager, the
  scheduler and multus are host-network.

If one of these ever moves to the pod network (a Rook `network.provider` change), it becomes an endpoint and falls under the
namespace policy: re-run the vetting below first.

### Vetting a namespace

1. Inventory the workloads (`kubectl get pods -o wide`, which are `hostNetwork`), the Services, HTTPRoutes (Gateway backends),
   admission webhooks and APIServices that point at the namespace, and the ServiceMonitors/PodMonitors that scrape it.
2. Capture flows for 20+ minutes with Hubble and keep the distinct shapes (source identity, destination identity, protocol, port):

   ```sh
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe \
     --server $(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}'):80 \
     --follow --namespace <ns> -o json | tools/netpol-replay aggregate shapes-<ns>.json
   ```

   (The agent resolves no cluster names; use the relay's ClusterIP.) Rare callers need their own reasoning: webhooks, Jobs and
   CronJobs that did not run during the capture, the e2e harness, LAN clients.
3. Render and replay: `tools/netpol-replay replay --namespace <ns> shapes-<ns>.json` evaluates every ingress shape against the
   rendered rules with Cilium's matching rules and must report 0 dropped and 0 without a policy. `--without ports,entities,endpoints`
   is the negative control: with those rules removed the same capture must produce drops. `tools/netpol-replay calibrate` compares
   the replay with Cilium itself on the live policies (`hubble observe --type policy-verdict -o json` names the policy that allowed
   each flow); run it after changing the tool.
4. After the merge: `hubble observe --verdict DROPPED --to-namespace <ns>` on an agent for 60 minutes, nothing `POLICY_DENIED`; the
   `NetworkPolicyDrops` alert (`nixidy/system/observability/prometheus.nix`) stays silent; the namespace's Gatus checks stay green.

### storage

Pod-network workloads (the only ones the policy selects): the CNPG, Dragonfly, ClickHouse, Rook and ceph-csi operators, the two
CSI provisioners (`ctrlplugin`), `rook-discover`, VolSync and the ClickHouse server.

| Caller | Callee | Rule |
| --- | --- | --- |
| kubelet probes | every workload (:8081, ClickHouse :8123) | baseline `host` |
| apiserver | CNPG webhook :9443 (the Service's :443; failurePolicy Fail on `cnpg-validating-webhook-configuration`) | baseline `host`/`remote-node`/`kube-apiserver` |
| Prometheus | CNPG :8080, Dragonfly operator :8443, ClickHouse operator :8888/:9999, VolSync :8443 | baseline scrape |
| ClickHouse operator | ClickHouse server :8123 (reconcile and metrics) | `extraIngress`, the only named rule |
| Ceph clients (CSI node plugins, kubelet mounts, rgw users, the operator) | Ceph daemons | not selected (host network) |

Nothing else calls into the namespace: the CNPG and Dragonfly operators call out (to the database pods in other namespaces,
which have their own `cnpg`/`dragonfly` rules), VolSync movers run in the app namespaces and talk to B2, no HTTPRoute backend is
a pod-network workload (`rook.<domain>` and `rados.<domain>` point at the host-network mgr and rgw; the baseline `ingress` entity
stays for them should Ceph ever leave the host network), and there are no LoadBalancer Services.

## Egress (design, not implemented)

Egress is open everywhere except `ai-sandbox/openclaw`, the one workload with an egress policy (`openclaw-egress`, a Kubernetes
NetworkPolicy in `nixidy/system/ai/openclaw.nix`: DNS, Bifrost and ContextForge, HTTPS anywhere for Discord). Ingress default-deny
already stops a compromised pod from reaching other pods' services; egress policy would additionally stop one from calling out
(exfiltration, command and control, lateral calls to the apiserver or the Gateway). It pays only where the set of destinations is
small and fixed.

### Why the app namespaces stay open

Apps reach arbitrary external APIs (metadata and request providers, indexers, B2, GitHub, Cloudflare, Discord, IdPs), the Gateway
VIP (`*.trdos.me` resolves to 192.168.50.241 inside the cluster too, and OIDC discovery and image pulls go through it) and, through
oauth2-proxy, Services in every namespace. An allowlist wide enough for that is `world:443` plus DNS, which isolates nothing and
costs a rule per new integration. FQDN rules (`toFQDNs`) need Cilium's DNS proxy on every selected pod, and a per-app hostname list
rots as providers change. `cicd` (ArgoCD fetches any repository, Harbor and Workflows pull and run arbitrary images, everything
talks to the apiserver) and `observability` (Prometheus and Gatus scrape or probe every namespace, Alloy reads everything) are in
the same position and stay open too.

### Mechanics a rule set has to respect

- A policy with an `egress` section that selects an endpoint turns egress default-deny for it. The baseline of every namespace
  policy would be: DNS to the CoreDNS pods (`k8s-app: coredns`, :53 UDP and TCP, with `rules.dns` `matchPattern: "*"` when any
  `toFQDNs` rule is present), the apiserver (`toEntities: kube-apiserver`, :6443: the `kubernetes` Service DNATs to the control-plane
  nodes and Cilium matches the post-DNAT address, so a rule on :443 matches nothing), OTLP and Pyroscope pushes to `observability`
  (Alloy :4317/:4318, Pyroscope :4040, for pods that run an SDK), and the namespace's own pods.
- Host-network destinations are `host`/`remote-node` entities (Ceph mons :3300 and daemons :6800-7568, the kubelet, the apiserver nodes);
  external destinations are `toFQDNs` (names known: B2, Bitwarden, Cloudflare, Let's Encrypt) or `toCIDR` (Cloudflare tunnel edge,
  1.1.1.1/9.9.9.9 resolvers).
- DNS is the dependency: a namespace under egress policy stops resolving the moment CoreDNS is unreachable, and the policy
  that governs CoreDNS is the `kube-system` one. Egress follows the `kube-system` ingress rollout and is flipped one namespace at a
  time, behind the replay (`tools/netpol-replay report --namespace <ns> shapes.json` lists the egress destinations per workload
  from the same capture).
- Rollback has a catch: ArgoCD itself needs DNS to fetch a revert. Egress for `cicd` stays out of scope for that reason, and a
  DNS-affecting change gets the break-glass step in its PR (pause the `netpol` Application's automated sync, delete the policy).

### Candidates, in order

Observed in a 40-minute Hubble capture (2026-10-16 09:59 to 10:39 UTC, 1.8M egress flows from `identity`, `security`, `observability` and `cicd`, plus the `storage` and `kube-system` captures); destinations that only the repo shows (nothing in the capture window) are marked "repo".

| Namespace | Destinations (everything else denied) | Why / risk |
| --- | --- | --- |
| `security` | DNS; apiserver; ESO to `bitwarden-sdk-server` :9998 (own namespace); `bitwarden-sdk-server` to `api.bitwarden.com` and `identity.bitwarden.com` :443 (repo: `external-secrets/bitwarden.nix`); cert-manager to `acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org`, `api.cloudflare.com` :443 and the DoH resolvers `1.1.1.1`/`1.0.0.1` :443 (repo: `cert-manager.nix`; issuance and renewal only) | Holds every secret in the cluster, and has the smallest destination set. Per-workload rules (the SDK server is the only one that reaches Bitwarden). A wrong rule fails secret sync, so ExternalSecrets go stale, not down |
| `storage` | DNS; apiserver; Ceph (`host` and `remote-node`: mons :3300, msgr2 only, OSD/MDS/mgr :6800-7568); CNPG operator to every `cnpg.io/cluster` pod :8000 and :5432, Dragonfly operator to Dragonfly pods :6379/:9999, ClickHouse operator to the server :8123; VolSync, ceph-csi and Rook to the apiserver only | No `world` destination at all. The Ceph port list is the risk (a missed OSD port stalls I/O), so it comes from `ceph config get osd ms_bind_port_min/max` (6800-7568) and the mon map (v2, :3300), not from a capture |
| `identity` | per workload: Keycloak to its Postgres :5432, `mail/stalwart` :25 (repo), Alloy; the Keycloak operator to the apiserver and Keycloak :8080; oauth2-proxy to Dragonfly :6379, the Gateway VIP :443 (OIDC discovery, repo) and its upstreams (repo, `oauth2Proxy.upstreams`: ports per namespace, as the ingress side already derives them); Postgres to B2 :443 | Login depends on it. Medium size, worth it for Keycloak and the Postgres pods; oauth2-proxy stays wide because it fronts every namespace |
| `kube-system` | per workload: CoreDNS to its upstream resolvers (`1.1.1.1`/`1.0.0.1` :53) and the apiserver; lan-dns to `1.1.1.1`/`9.9.9.9` :53; cloudflared to the Cloudflare edge (UDP :7844) and the Gateway; external-dns to `api.cloudflare.com`; external-dns-internal to AdGuard (`100.64.0.1:3000`, tailnet); Hubble relay to the agents :4244; k8tz and the snapshot controller to the apiserver | Last: it governs DNS for the whole cluster, so a mistake is cluster-wide. CoreDNS forwards to the node's `resolv.conf`, so its upstream list must follow the nodes' |

### Follow-up PRs

1. Module: an `egress` option set in `netpol.nix` (`netpol.namespaces.<ns>.egress.{enforce,extraEgress}`), the baseline above, and
   per-workload selectors; `tools/netpol-replay replay` learns egress (it already captures it). No namespace enabled.
2. `security` egress (smallest, best signal) with a 60 minute watch and a forced ESO refresh and cert-manager renewal check.
3. `storage` egress after reading the Ceph port range from the cluster.
4. `identity` egress, Keycloak and Postgres first, oauth2-proxy last.
5. `kube-system` egress.
