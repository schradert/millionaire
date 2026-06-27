---
name: Cilium L2 announcement source IP bug with native routing
description: Cilium L2-announced VIPs return traffic from node's real IP instead of VIP when announcing node is also the backend, with native routing mode
type: project
---

When Cilium L2 announces a LoadBalancer VIP and the announcing node is also where the backend pod runs, responses come from the node's real IP (e.g. 192.168.50.204) instead of the VIP (192.168.50.242). Clients reject these as "reply from unexpected source."

This happens with `routingMode = "native"` and `autoDirectNodeRoutes = true` — Cilium short-circuits the DNAT/SNAT path on the local node.

When a *different* node holds the L2 lease, it works because cross-node forwarding goes through proper SNAT. But this adds latency and a dependency on that node's connectivity.

**Why:** This caused two outages on 2026-04-15 when trying to pin AdGuard DNS to sirver with `externalTrafficPolicy: Local`.

**How to apply:** Don't use `externalTrafficPolicy: Local` with Cilium L2 announcements + native routing when the goal is same-node announcement. The AdGuard Home DNS setup was removed from the home network as a result; a headscale VPN + cloud VPS approach is being considered instead.
