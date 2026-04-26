# Tailscale Integration for Multi-Cluster (Phase 2)

## Current State (Phase 1 ✅)

Your cluster uses:
- **Pod Network**: Cilium on `10.42.0.0/16` (managed by Cilium CNI)
- **Service Network**: `10.43.0.0/16` (Kubernetes ClusterIP services)
- **LoadBalancer IPs**: `192.168.50.240-254` (Cilium LB-IPAM, home network)
- **Node Network**: `192.168.50.0/24` (your home LAN)

## Goal (Phase 2)

Connect to brother's Tokyo cluster:
- Each cluster remains independent (separate control planes)
- Clusters can expose specific services to each other
- Use Tailscale for cross-cluster connectivity

## 🐉 HERE BE DRAGONS 🐉

### Dragon 1: Network Interface Confusion

**The Problem:**
- RKE2 needs to know which interface to use for node communication
- Cilium needs to know which interface to use for pod routing
- Tailscale creates a new interface (`tailscale0`)

**The Solution:**
```nix
# RKE2 uses home network for intra-cluster (low latency)
# Tailscale used ONLY for cross-cluster gateway IPs

# /etc/rancher/rke2/config.yaml (on each node)
node-ip: 192.168.50.X      # Home network IP (NOT Tailscale IP)
node-external-ip: 100.64.1.X  # Tailscale IP (for cross-cluster)
```

**Why:**
- Local pod-to-pod stays on fast home network
- Cross-cluster traffic uses Tailscale (slower but encrypted)

### Dragon 2: MTU Mismatch

**The Problem:**
- Home network MTU: 1500
- Tailscale overhead: ~80 bytes
- If pods try to send 1500 byte packets through Tailscale → fragmentation

**The Solution:**
```nix
# Cilium detects MTU automatically, but can override:
nixidy.system.network.cilium.helm.values = {
  # Let Cilium auto-detect MTU (recommended)
  # It will see 1500 on br0 and adjust for encapsulation
  mtu = 0;  # Auto-detect

  # OR manually set if you have issues:
  # mtu = 1420;  # 1500 - 80 (Tailscale overhead)
};
```

### Dragon 3: IP Range Conflicts

**The Problem:**
- Your pod CIDR: `10.42.0.0/16`
- Your service CIDR: `10.43.0.0/16`
- Tailscale CIDR: `100.64.0.0/10`
- Brother's pod CIDR: Must not overlap!

**The Solution:**
```nix
# Coordinate with brother:
# Your cluster:  10.42.0.0/16 (pods), 10.43.0.0/16 (services)
# His cluster:   10.44.0.0/16 (pods), 10.45.0.0/16 (services)
# Tailscale:     100.64.0.0/10 (node overlay network)
# Home LB pool:  192.168.50.240/28
# Tailscale LB:  100.64.1.240/28 (future, for cross-cluster gateways)
```

### Dragon 4: DNS Resolution

**The Problem:**
- Tailscale MagicDNS: `node.tailnet.ts.net`
- Kubernetes CoreDNS: `service.namespace.svc.cluster.local`
- Your domain: `*.trdos.me`
- Brother's domain: `*.tokyo.something`

**The Solution:**
```nix
# Use separate DNS zones:
# 1. Intra-cluster: CoreDNS handles *.svc.cluster.local
# 2. Cross-cluster: Create DNS records pointing to Tailscale gateway IPs
# 3. Internet: Cloudflare handles *.trdos.me

# Example:
# internal.yourcluster.home → 100.64.1.240 (your internal gateway on Tailscale)
# internal.tokyo.home → 100.64.2.240 (brother's gateway on Tailscale)
```

### Dragon 5: Firewall Rules

**The Problem:**
- NixOS firewall might block Tailscale
- Cilium has eBPF firewall
- Need both to allow cross-cluster traffic

**The Solution:**
```nix
# NixOS config for each node
networking.firewall = {
  enable = true;

  # Trust Tailscale interface
  trustedInterfaces = ["tailscale0"];

  # Already trusting Cilium interfaces
  trustedInterfaces = ["cilium+" "lxc+" "tailscale0"];

  # Allow Tailscale UDP port
  allowedUDPPorts = [ 41641 ];  # Tailscale default
};

# Tailscale
services.tailscale.enable = true;
```

### Dragon 6: Routing Tables

**The Problem:**
- Cilium manages routes for pod network
- Tailscale adds routes for its network
- Linux kernel needs to know which route to use

**The Solution:**
```bash
# After enabling Tailscale, check routing:
ip route show

# You should see:
# 10.42.0.0/16 via cilium (pod network)
# 192.168.50.0/24 via br0 (home network)
# 100.64.0.0/10 via tailscale0 (Tailscale network)

# NO OVERLAP - each route is distinct
```

## Safe Implementation Steps

### Step 1: Enable Tailscale on ONE test node

```nix
# modules/nixos.nix (or similar)
{
  # Add Tailscale
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";  # Allow subnet routing
  };

  # Trust Tailscale interface
  networking.firewall.trustedInterfaces = ["tailscale0"];
}
```

### Step 2: Connect node to Tailscale and verify

```bash
# On the node
sudo tailscale up --accept-routes

# Check Tailscale IP
tailscale ip -4
# Should show: 100.64.x.x

# Check node can still reach other nodes on home network
ping 192.168.50.204  # Other node's home IP

# Check Cilium is still happy
cilium status
```

### Step 3: Create Tailscale IP pool in Cilium (DO NOT USE YET)

```nix
# cilium.nix - ADD this alongside home-pool
resources.ciliumLoadBalancerIPPools.tailscale-pool.spec = {
  blocks = lib.toList {
    start = "100.64.1.240";
    stop = "100.64.1.254";
  };
  # Important: These IPs must be within your Tailscale subnet!
};

# DO NOT assign gateways to this pool yet
```

### Step 4: Test cross-cluster connectivity

```bash
# From your node, ping brother's node via Tailscale
ping 100.64.2.X  # Brother's Tailscale IP

# If this works, network layer is good
```

### Step 5: Create cross-cluster gateway (FUTURE)

```nix
# gateway.nix - add a THIRD gateway for cross-cluster
resources.gateways.cross-cluster = gateway "cross-cluster" {
  metadata.annotations = {
    "io.cilium/lb-ipam-ips" = "tailscale-pool";  # Use Tailscale pool
  };
  # ... same config as internal gateway
};
```

### Step 6: Expose specific services via HTTPRoute

```nix
# Only expose services you WANT brother to access
resources.httpRoutes.shared-service = {
  spec.parentRefs = [{
    name = "cross-cluster";  # The Tailscale gateway
    namespace = "kube-system";
  }];
  spec.hostnames = ["myapp.yourcluster.home"];
  spec.rules = [{
    backendRefs = [{
      name = "my-app";
      port = 8080;
    }];
  }];
};
```

## Recommended Architecture

```
┌─────────────────────────────────────────────────┐
│           Your Cluster (Home)                   │
│                                                 │
│  ┌──────────────┐  ┌─────────────┐             │
│  │ Internal GW  │  │External GW  │             │
│  │192.168.50.240│  │192.168.50.241│             │
│  │(home LAN)    │  │(home LAN)   │             │
│  └──────────────┘  └─────────────┘             │
│         ↓                 ↓                     │
│    Local Access    Cloudflare Tunnel           │
│                                                 │
│  ┌──────────────┐                               │
│  │Cross-Cluster │  ← Future, when needed       │
│  │   Gateway    │                               │
│  │100.64.1.240  │                               │
│  │(Tailscale)   │                               │
│  └──────┬───────┘                               │
└─────────┼─────────────────────────────────────┘
          │
          │ Tailscale VPN
          │
┌─────────┼─────────────────────────────────────┐
│         │      Brother's Cluster (Tokyo)       │
│  ┌──────▼───────┐                               │
│  │Cross-Cluster │                               │
│  │   Gateway    │                               │
│  │100.64.2.240  │                               │
│  │(Tailscale)   │                               │
│  └──────────────┘                               │
│         ↓                                       │
│    Shared Services                              │
└─────────────────────────────────────────────────┘
```

## Traffic Flows

**Intra-cluster (fast, local):**
```
Pod A → Pod B (same cluster)
  ↓
Cilium routing on home network (192.168.50.0/24)
  ↓
Direct, ~1ms latency
```

**External users → Your services:**
```
Internet → Cloudflare → Tunnel → External Gateway (192.168.50.241)
  ↓
Gateway → HTTPRoute → Service → Pod
```

**Cross-cluster (slow, encrypted):**
```
Your Pod → Brother's Service
  ↓
Cross-Cluster Gateway (100.64.1.240)
  ↓
Tailscale VPN (encrypted)
  ↓
Brother's Cross-Cluster Gateway (100.64.2.240)
  ↓
Brother's Service → His Pod
```

## Testing Checklist

Before enabling Tailscale in production:

- [ ] Verify Cilium LB-IPAM works on home network
- [ ] Gateways get IPs from home pool (192.168.50.240-254)
- [ ] External-DNS creates records correctly
- [ ] Cloudflare tunnel works with dynamic gateway IPs
- [ ] Install Tailscale on ONE node
- [ ] Verify pod networking still works on that node
- [ ] Check routing table looks correct
- [ ] Ping brother's Tailscale IP successfully
- [ ] Create test cross-cluster gateway
- [ ] Verify it gets Tailscale IP from pool
- [ ] Test HTTP request across clusters
- [ ] Measure latency (expect ~150-200ms to Tokyo)
- [ ] Roll out Tailscale to all nodes

## Rollback Plan

If Tailscale breaks things:

```bash
# Disable Tailscale on node
sudo systemctl stop tailscaled
sudo tailscale down

# Rebuild without Tailscale
nixos-rebuild switch

# Verify cluster recovers
cilium status
kubectl get nodes
```

## When NOT to Use Tailscale

Don't use Tailscale cross-cluster gateway if:
- Services need low latency (<50ms)
- High throughput required (>100MB/s sustained)
- Real-time applications (gaming, video calls)

Instead:
- Run those services locally in each cluster
- Use CDN/edge caching
- Replicate data instead of live cross-cluster calls

## Questions to Answer First

1. **What services do you want to share with brother?**
   - Databases?
   - APIs?
   - Monitoring dashboards?
   - Admin tools?

2. **What's the traffic pattern?**
   - Occasional API calls? ✅ Tailscale is fine
   - Real-time streaming? ❌ Too slow

3. **Do you trust brother's cluster?**
   - If yes: Can expose internal services
   - If no: Only expose authenticated public APIs

4. **Who manages DNS?**
   - Centralized (you manage both)? Easier
   - Separate (each manages own)? Need coordination

## Next Steps

1. **NOW**: Deploy Cilium LB-IPAM changes (Phase 1)
2. **TEST**: Verify gateways get dynamic IPs
3. **THEN**: Read this doc thoroughly
4. **COORDINATE**: Talk to brother about IP ranges
5. **EXPERIMENT**: Enable Tailscale on one node
6. **VALIDATE**: Test cross-cluster connectivity
7. **DEPLOY**: Roll out to production

## Resources

- [Cilium LB-IPAM docs](https://docs.cilium.io/en/stable/network/lb-ipam/)
- [Tailscale subnet routers](https://tailscale.com/kb/1019/subnets)
- [RKE2 networking](https://docs.rke2.io/networking)
- [Kubernetes multi-cluster](https://kubernetes.io/docs/concepts/cluster-administration/networking/#multi-cluster-networking)
