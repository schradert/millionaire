---
name: No untested infrastructure changes
description: Never deploy infrastructure changes (especially networking/DNS) without being confident they work — broken DNS takes down the entire home network
type: feedback
---

Do not deploy cluster networking changes (Cilium L2 policies, externalTrafficPolicy, service changes) without high confidence they'll work. A bad change to DNS infrastructure takes down the entire home network for all devices.

**Why:** externalTrafficPolicy: Local was deployed twice and broke all internet connectivity both times, requiring emergency hotspot switching and manual reverts — which ArgoCD then fought against.

**How to apply:** When making changes that affect DNS or L2 announcement paths, verify the exact behavior first (e.g. in a test namespace or by reading Cilium source). Never assume Cilium L2 + native routing behaves like standard kube-proxy. Always have a rollback plan that doesn't depend on the thing being changed (e.g. don't rely on DNS to fix DNS).
