# Internal services + ad-blocking over the tailnet

Internal cluster services (`*.trdos.me`) and ad-blocking DNS are delivered to
personal devices (laptop, PC, phone) **only over the tailnet** — there is no
public exposure. This rides the same headscale tailnet that cloud-burst uses
(see [`cloud-burst.md`](cloud-burst.md)) but is an independent capability.

## How it fits together

```
device (tailnet) ──DNS──▶ AdGuard @ 100.64.0.1:53 (hyena)
                            ▲ records written by
                            │ external-dns-internal (in-cluster → AdGuard :3000 API)
device ──HTTP──▶ 192.168.50.241 (internal gateway VIP) ──▶ Service ──▶ Pod
        (reached over the tailnet via a cluster node advertising 192.168.50.241/32)
```

1. **AdGuard on hyena** is the resolver for tailnet devices: headscale pushes it
   via `dns.override_local_dns = true; dns.nameservers.global = ["100.64.0.1"]`
   (`static/hyena.nix`). Devices get ad-blocking **and** internal-name resolution.
   `magic_dns = false` — no MagicDNS search domain is pushed (a leaked search
   domain previously hijacked pod DNS; keep it false).
2. **`external-dns-internal`** (nixidy) watches internal-gateway HTTPRoutes and
   writes `<name>.trdos.me → 192.168.50.241` into AdGuard's `:3000` API. (The
   public `external-dns` writes the same names to Cloudflare for non-excluded
   routes.)
3. **The internal gateway VIP `192.168.50.241`** (Cilium L2 LB-IPAM, `home-pool`)
   is where services actually live. Cluster nodes advertise `192.168.50.241/32`
   as an auto-approved tailnet subnet route, so an off-LAN device routes to it
   over the tailnet via a cluster node. The DNS answer is the gateway VIP, **not**
   hyena's IP — hyena hosts DNS, not the services.

## hyena (headscale + AdGuard)

- AdGuard binds the **tailnet IP `100.64.0.1`**, not `0.0.0.0` — `0.0.0.0:53`
  collides with systemd-resolved's stub on `127.0.0.53` (hyena's *own* resolver).
  `boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1` lets AdGuard bind that IP
  before tailscaled assigns it at boot.
- The AdGuard config is delivered as a **seed**: sops renders the template to its
  default path; a `preStart` copies it to a writable, `adguardhome`-owned
  `/var/lib/AdGuardHome/AdGuardHome.yaml` only if none exists (AdGuard rewrites
  its own config at runtime, so sops must not own the live file).
- hyena is itself a tailnet member (it self-registers to its own headscale), so
  its hosted AdGuard is reachable at the stable mesh IP `100.64.0.1`.

## Cluster nodes opt OUT of the pushed resolver

The headscale DNS push is tailnet-global, so cluster nodes are explicitly
excluded with `--accept-dns=false` (`static/tailnet.nix`). Otherwise every node
(and CoreDNS's upstream) would resolve through hyena over the tailnet — coupling
cluster DNS to hyena's availability — and a pushed search domain could re-leak
into pods.

> **NixOS gotcha:** `extraUpFlags` only apply on the *first* `tailscale up`; the
> autoconnect unit exits early when the node is already `Running`. So a
> post-autoconnect oneshot re-asserts `tailscale set --accept-dns=false` on every
> activation. Verify with `tailscale debug prefs | grep CorpDNS` → `false`.

## Routing facts

- **Cilium runs its own pod pool: `10.0.0.0/8`** (`ipv4NativeRoutingCIDR`,
  `cilium.nix`), a `/24` per node. The k8s `Node.podCIDR` (`10.42.0.0/16`) is
  **vestigial** — Cilium ignores it. So the headscale **autoApprover** keys on
  `10.0.0.0/8`, and the cluster nodes register as user **`default` (untagged)**, so
  the approver covers `default@` (plus `tag:cluster` for future cloud workers):
  ```nix
  autoApprovers.routes = {
    "10.0.0.0/8"        = ["tag:cluster" "default@"];   # Cilium pod /24s
    "192.168.50.241/32" = ["tag:cluster" "default@"];   # internal gateway VIP
  };
  ```
- `kubeProxyReplacement = true`, so ClusterIP service traffic (`10.43.0.0/16`) is
  eBPF-handled and never hits the host route table.
- autoApprover-approved routes can show a blank "Approved" column in
  `headscale nodes list-routes`; the `applying route approval results
  newApprovedRoutes=[…]` log line and a "Serving (Primary)" entry are
  authoritative.

## Adding a device

1. `tailscale up --login-server=https://headscale.trdos.me` on the device;
   approve it (`headscale nodes list` on hyena).
2. The device picks up AdGuard automatically (override_local_dns) → ad-blocking +
   `*.trdos.me`. On the home LAN it reaches `192.168.50.241` directly; off-LAN it
   uses the advertised `192.168.50.241/32` route via a cluster node.

## Known gaps / TODO

- **Off-LAN datapath** (device → cluster node → Cilium L2 VIP) interacts with the
  Cilium L2 source-IP behaviour and subnet-route SNAT — validate from a real
  off-LAN client. See `project_cilium_l2_native_routing_bug`.
- **`tailnet.podSupernet` is now `10.0.0.0/8`** (Cilium's pool) and the supernet
  route is deployed on all home nodes — verified it does **not** divert home↔home
  pod traffic (LAN `/24`s win by longest-prefix) or services (eBPF socket-LB
  intercepts before the route table). The *cross-site* path itself (home pod ↔
  worker pod over the tailnet) still needs a real cloud worker to exercise — that
  is the cloud-burst datapath spike. (A stale `10.42.0.0/16` route lingers on
  already-running nodes from the old value; it's inert and self-clears on reboot.)

## Deploying changes

Node config is applied via deploy-rs. From a host that isn't on the home LAN,
reach the nodes through hyena as an SSH jump (hyena's public IP resolves from
`headscale.trdos.me`):

```sh
deploy --skip-checks --hostname <node-tailnet-IP> \
  --ssh-opts "-J root@<hyena-public-ip> -o StrictHostKeyChecking=accept-new" '.#<node>'
# node tailnet IPs (100.64.0.x): sirver .2  octopus .3  bonobo .4  chinchilla .5  dingo .6
# hyena itself: --hostname <hyena-public-ip> --ssh-user root  (no jump)
```

These are `switch`es (no reboot), so the OSD/etcd reboot hazards from the
node-reinstall path don't apply.
