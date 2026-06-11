# Cloud-burst: CAPI-managed Hetzner workers — runbook

When home capacity runs out, the cluster rents it: pending pod → Cluster
Autoscaler scales a MachineDeployment → CAPH boots a Hetzner VM from the
prebaked NixOS snapshot → it joins the tailnet + RKE2 → pod schedules. Idle
10 minutes → drain → VM deleted → headscale drops the ephemeral peer.

Architecture decisions and their rationale live in the PR series
(`cloud-burst/00`–`06`). The short version: **scoped CAPI** — CAPI manages
only machines that have a create/destroy API (cloud VMs). Home nodes stay
Pulumi-managed; there is no controlPlaneRef, no bootstrap provider (since
the `dataSecretName` bypass carries hand-authored cloud-init),
no CCM (workers self-set `provider-id`; a CCM's node-lifecycle controller
could delete home Node objects in a hybrid cluster), and Cilium stays in
native routing everywhere (tailscale subnet routes are the cross-site
fabric).

## One-time prerequisites

1. Create the **millionaire-capi** Hetzner project in the console (projects
   have no create API), generate an API token, then:
   `pulumi config set --secret hcloudCapiToken <token>`
2. Merge order: the nixidy switch requires main to render — PR #32's
   app-template fixes must land before the capi PRs are switch-applied.

## Phase rollout (each independently verifiable)

### 1. Tailnet (PR #38) — `pulumi up` from the LAN

Pulumi ordering is wired: hyena deploy (policy) → tagged preauth keys →
SOPS write → node deploys → sirver IP capture.

- [ ] `ssh sirver tailscale status` — logged in; `headscale nodes list` on
      hyena shows 5 cluster peers, tagged `tag:cluster`
- [ ] each node advertises its pod /24 and it is auto-approved
      (`headscale nodes list-routes`)
- [ ] home↔home pod traffic still on the LAN: `tcpdump -i tailscale0` quiet
      for sibling pod CIDRs; `cilium status` green; `kubectl get nodes`
      unchanged (no node-IP flips)
- [ ] BWS has `headscale/preauth-key/k8s-cloud-worker`, `rke2/agent-token`,
      `headscale/node-ip/sirver`

### 2. Cilium prep (PR #39) — `nixidy switch`

All home no-ops: `direct-routing-skip-unreachable=true`, the eth0 entry in
the cilium devices list, and the L2 policy excluding `node.trdos.me/burst`.

- [ ] cilium agents healthy after rollout; LAN VIPs still announced

### 3. Worker image + datapath spike (PR #41) — before any CAPI lands

Running `pulumi up` (with the capi token configured) builds + uploads the snapshot.
Then boot ONE worker manually:

```sh
hcloud server create --type cpx31 --name spike --location nbg1 \
  --image <snapshot id> --user-data-file spike-user-data.yaml
```

The `spike-user-data.yaml` content is the rendered bootstrap secret — after
PR #43 syncs, extract it with:

```sh
kubectl -n capi get secret cloud-worker-bootstrap -o jsonpath='{.data.value}' | base64 -d
```

(or hand-write the three `write_files` + sentinel runcmd before then).

- [ ] worker appears in `headscale nodes list` (ephemeral) with its pod /24
      approved; `kubectl get nodes` shows it Ready with the burst label
- [ ] expected boot noise: ONE sops activation warning (image has no age key)
- [ ] pod↔pod both directions (home pod ↔ burst pod), cross-site ClusterIP,
      DNS from a burst pod
- [ ] large transfer across sites (MTU/PMTUD truth test): e.g. `kubectl cp`
      a ~100MB file or iperf via pod IPs — watch for stalls
- [ ] multi-hour soak: rke2-agent stays connected (its supervisor LB learns
      unreachable LAN server IPs — verify it keeps using the pinned sirver
      address without flapping; `journalctl -u rke2-agent | grep -i 'connect'`)
- [ ] teardown: `hcloud server delete spike` → headscale peer vanishes
      (ephemeral), `kubectl delete node spike` (manual only for the spike —
      CAPI handles this from phase 4 on)

If native routing fundamentally fails on the TUN path (it should not — k3s
ships this shape), the fallback ladder is: targeted fixes (MSS clamp scope,
interface naming) first; cluster-wide tunnel mode is the last resort and
costs the home LAN its native datapath.

### 4. CAPI operator + cluster resources (PRs #42, #43) — `nixidy switch`

- [ ] `kubectl get coreprovider,infrastructureprovider -A` both Ready
      (contract mismatch → pin CoreProvider to the highest core minor CAPH
      v1.1.6 declares)
- [ ] ESO synced: `hetzner`, `cloud-worker-bootstrap`,
      `millionaire-kubeconfig` Secrets in ns capi (TokenRequest needs the
      external-secrets chart's serviceaccounts/token RBAC — present in the
      upstream chart)
- [ ] kubeconfig works:
      `kubectl --kubeconfig <(kubectl -n capi get secret millionaire-kubeconfig -o jsonpath='{.data.value}' | base64 -d) get nodes`
- [ ] `kubectl get cluster -n capi` — infrastructure Ready;
      **ControlPlaneInitialized stays False forever — expected and cosmetic**
- [ ] manual scale test:
      `kubectl -n capi scale machinedeployment cloud-worker-cpx31 --replicas=1`
      → Machine Provisioned → Running, NodeRef set (providerID match), node
      Ready; back to 0 → drain → VM deleted → Node object removed by CAPI

### 5. Autoscaler (PR #44 branch) — `nixidy switch`

- [ ] burst test: deploy with requests exceeding home capacity → CA logs
      `Scale-up`, MachineDeployment 0→1, pod schedules on the burst node
- [ ] delete the deployment → after ~10m unneeded: cordon, drain, VM gone,
      headscale peer gone
- [ ] scale-from-zero works via the capacity annotations (no live node needed
      for CA to size the pool)

### 6. Resilience

- [ ] MachineHealthCheck: `systemctl stop rke2-agent` on a worker → after 5m
      NotReady the Machine is remediated (replaced)
- [ ] rolling image bump: change worker config → `pulumi up` re-uploads the
      snapshot → workers churn naturally (scale-to-zero) or delete Machines
      to force replacement

## Canary after every CAPI/CAPH/operator version bump

The external-control-plane + dataSecretName combination is contractual but
has no upstream CI. After bumping versions in `capi-operator.nix`:
scale the MachineDeployment 0→1→0 and watch Machine phases. Two minutes of
canary beats a silent breakage discovered during a real burst.

## Known footguns

- **Argo vs autoscaler on replicas**: handled via `ignoreDifferences` on
  `/spec/replicas` — do not remove it.
- **Snapshot label ambiguity**: CAPH errors if multiple snapshots carry
  `caph-image-name=cloud-worker`; the pulumi upload deletes stale ones first.
  Never upload that label manually.
- **The worker key is ephemeral+reusable**: peers self-clean on scale-down.
  If workers vanish from the tailnet while running, check key expiry
  (8760h) — recreate via pulumi (taint `headscale_preauthkey_cloud_worker`).
- **Home nodes must never run `--accept-routes`** (tailscale's policy table
  outranks the main routing table and would divert LAN pod traffic into
  WireGuard). The static supernet route in `tailnet.nix` is the design.

## Adding a second provider later (the point of CAPI)

Price-shopping another cloud = one InfrastructureProvider CR
(`capi-operator.nix`), an image build for that cloud + upload pipeline, a
per-provider MachineDeployment + machine template (`capi-cluster.nix`), and
a providerID story (that provider's CCM or a static kubelet arg from
metadata, as here). The bootstrap data, tailnet design, autoscaler, and
kubeconfig are provider-agnostic and reused as-is. Rank pools by price with
the autoscaler's priority expander (a git-tracked ConfigMap) when the time
comes.
