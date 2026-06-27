---
name: coredns-magicdns-search-hijack
description: "tailscale MagicDNS ts.trdos.me search domain leaks into pods via kubelet and collides with CoreDNS's *.trdos.me wildcard under ndots:5, hijacking pod external DNS to the internal gateway VIP"
metadata:
  node_type: memory
  type: project
  originSessionId: 3f78a774-3db0-4426-b490-4aa167e2a086
---

Diagnosed 2026-06-21. Symptom: many pods CrashLoop on i/o timeouts to `192.168.50.241` (the `cilium-gateway-internal` LoadBalancer VIP) — external-dns, external-dns-internal, oauth2-proxy, etc. Looks like a Cilium/L2 failure but is **pure DNS**.

Chain:
1. tailscaled registers MagicDNS suffix `ts.trdos.me` as a **search domain** on `tailscale0` (`--accept-dns`, headscale); systemd-resolved promotes it into the node `/etc/resolv.conf` `search` line.
2. kubelet has no `--resolv-conf` override → copies node search domains into **every pod** (pod resolv.conf: `search …cluster.local ts.trdos.me`, `ndots:5`).
3. With `ndots:5`, a Go/glibc client resolving a name with <5 dots tries **search suffixes first**: `api.cloudflare.com.ts.trdos.me.` ends in `.trdos.me.` → matches CoreDNS's intentional split-horizon wildcard `*.trdos.me → 192.168.50.241` (`nixidy/system/network/coredns.nix`) → returns the gateway VIP. Client connects there, no backend for its port → **timeout → crashloop**, never trying the real name.

Node resolver is unaffected (no CoreDNS, no wildcard) — only pods break. **Why it appeared "suddenly":** the wildcard is old; the `ts.trdos.me` search domain is new from the tailscale/headscale MagicDNS work.

Fast diagnosis: ephemeral `kubectl run dnstest --image=busybox:1.36 --rm -it --restart=Never -- sh -c "cat /etc/resolv.conf; nslookup <extname>; nslookup <extname>.ts.trdos.me"`. If the absolute name resolves correctly but `<extname>.ts.trdos.me` → `.241`, this is it. TCP to `.241:443`/`:80` is OPEN (gateway fine); `.241:6379` times out (no backend) — not an L2 problem (ARP for `.241` resolves to the lease-holder's NIC, lease fresh).

Fix (PR #47, `fix/coredns-tailscale-search-leak`): point kubelet at a curated `/etc/rke2-resolv.conf` (upstream `1.1.1.1`/`1.0.0.1`, **no search domain**) via `canivete.kubernetes.yaml.kubelet-arg = ["resolv-conf=/etc/rke2-resolv.conf"]` in `static/server.nix` (imported by all 5 nodes). Pods then get only cluster search domains; node systemd-resolved + MagicDNS untouched. Deploy = manual pulumi node-by-node (rke2 restarts per node — never all servers at once, see [[rke2-etcd-pipe-freeze-outage]]). Rejected the alternative of tightening the CoreDNS wildcard to single-label — masks the symptom, leaves the leak. This blocked the multus pre-merge gate ([[pr-split-2026-06-outcome]], [[nixidy-render-validation]]).
