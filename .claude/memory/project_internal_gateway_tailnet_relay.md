---
name: project-internal-gateway-tailnet-relay
description: "Internal Cilium gateway has a native tailnet IP via a systemd-socket-proxyd relay on bonobo (PR #64, deployed 2026-06-25); plus the ArgoCD-orphan + gateway-drift gotchas hit during rollout"
metadata:
  node_type: memory
  type: project
  originSessionId: 51a8160d-742c-4292-902c-aaae3926c374
---

**DEPLOYED + VALIDATED 2026-06-25 (PR #64, squash `50613ce` on main).** Off-LAN tailnet
clients reach internal `*.trdos.me` services over the headscale tailnet via a host-level
relay — replacing the fragile `192.168.50.241/32` subnet-route path and the inert pod-based
`tailscale-front` (both removed).

## The design
- **`static/tailnet.nix` `gatewayRelay` option** (a tailnet-IP string, null by default); set
  `tailnet.gatewayRelay = "100.64.0.4"` on **bonobo** in flake.nix. It instantiates two
  socket+service pairs: `systemd.sockets.gateway-relay-{443,80}` (ListenStream
  `100.64.0.4:443`/`:80`, `FreeBind=true`) → socket-activated `systemd-socket-proxyd
  192.168.50.241:{443,80}` (raw TCP, TLS/SNI pass through → envoy still Host-routes).
  `ExecStart` uses `${config.systemd.package}/lib/systemd/systemd-socket-proxyd`.
- **DNS:** `external-dns-internal` (writes ONLY to hyena's tailnet AdGuard `100.64.0.1:3000`)
  now writes `*.trdos.me → 100.64.0.4`, driven by the internal Gateway's
  `external-dns.alpha.kubernetes.io/target` annotation (`nixidy/system/network/gateway.nix`).
  Home-WiFi/CoreDNS resolution (→ `.241`) is a SEPARATE resolver — untouched.
- **Why a host relay, not a pod or tailscale node:** headscale denies `tailscale serve` (no
  serve/funnel capability), AND Cilium's eBPF L7LB tproxy refuses in-cluster pod→gateway
  connections (the cilium mystery — envoy never SYN-ACKs from a pod). A plain host socket
  sidesteps both. [[project_hyena_adguard_dns]]
- **Round-robin HA — DEPLOYED + validated 2026-06-26 (PR #65):** the relay runs on BOTH agents —
  bonobo `100.64.0.4` AND chinchilla `100.64.0.5` (`tailnet.gatewayRelay` set per-node in
  flake.nix). The gateway target annotation is comma-separated `"100.64.0.4,100.64.0.5"`; the
  muhlba91 AdGuard provider emits one rewrite per target (verified in its `provider.go`:
  `for _, t := range e.Targets`) and AdGuard returns BOTH A records (verified: `dig @100.64.0.1
  grafana.trdos.me` → both IPs; both relays return the gateway's 503). Clients round-robin and
  survive one relay node down **by client retry** — NOT health-checked failover (a dead relay's
  IP stays in AdGuard). [[project_internal_gateway_tailnet_relay]] TODO above.
- **The `.241/32` advertise was REMOVED** from `tailnet.nix` (PR #65, deployed to all 5 nodes
  node-by-node, etcd 3/3 between each — clean). Each node now advertises only its pod /24
  (verified via `tailscale debug prefs`). The `.241/32` autoApprover was also dropped from
  hyena.nix (PR #66, hyena deployed via deploy-rs — diff-closures = only the headscale policy
  source, no binary churn; headscale restarted clean, AdGuard + tunnels untouched), AND the
  residual per-node `.241/32` approval records (which persist after removing the autoApprover —
  they don't auto-clear) were dropped via `headscale nodes approve-routes -i <id> -r <pod /24>`
  (headscale 0.28; `approve-routes` REPLACES the approved set). `headscale nodes list-routes`
  now shows ONLY each node's pod /24 — fully clean, no `.241/32` anywhere. The tailscale-operator
  is also fully removed (app, 7 CRDs, ns, clusterrole/binding, ingressclass; `headscale/preauth-key/k8s`
  now free).
- **TODO (project): health-checked DNS for true relay failover.** external-dns has no relay
  health check, so round-robin only survives a node loss via client retry. True failover needs
  a liveness-gated record — e.g. a small controller that drops a relay node's IP from the
  gateway target when its `gateway-relay-*.socket` is down, or a health-checked DNS front.

## Rollout gotchas (reusable)
- **nixidy ArgoCD Applications have NO `resources-finalizer`** → `kubectl delete application
  <name> -n cicd` removes the Application CR but ORPHANS its resources (Deployment/PVC/etc).
  After deleting the app, delete the namespaced resources BY NAME. (And there is no
  app-of-apps, so removing an app from git's `generated/prod/apps/` does NOT delete the live
  Application — delete it manually.) The `tailscale` namespace is SHARED with the inert
  `tailscale-operator`/`proxies` — delete only `tailscale-front`-named resources.
- **Redeploying the relay over a running temp one fails** `gateway-relay-443.socket` with
  "Address already in use" — stop the old transient relay (`/run/systemd/system/gwrelay*.{socket,service}`)
  BEFORE starting the persistent socket; rm the runtime unit files (they aren't `--collect`ed).
- **Both Cilium Gateways (`internal` + `external`) sit perpetually OutOfSync in ArgoCD**
  (app Healthy) — pre-existing, NOT caused by annotation edits (external is OutOfSync too and
  was never touched). A Cilium-controller-mutated Gateway field needs an `ignoreDifferences`
  entry (same class as PR #61). selfHeal can't clear it. Cosmetic but masks real gateway drift.
- **Node deploy base:** bonobo built as `26.05.20260523.64c08a7` (= live nodes' nixpkgs);
  `nix store diff-closures` was clean (only the 4 relay units, no tailscale/nixpkgs delta) —
  confirms the branch (descends from `cloud-burst/06-rebased`) matches live. [[project_node_config_cloud_burst_base]]

Links: [[project_hyena_adguard_dns]], [[project_cilium_l2_native_routing_bug]], [[project_nixidy_render_validation]], [[feedback_no_untested_infra_changes]].
