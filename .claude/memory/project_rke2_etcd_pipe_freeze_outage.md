---
name: rke2-etcd-pipe-freeze-outage
description: 2026-06-11 cluster outage — all 3 etcd members frozen on full stderr pipes after simultaneous RKE2 upgrade; topology + recovery procedure
metadata:
  node_type: memory
  type: project
  originSessionId: 27828fc1-638f-47ac-b7e6-f291cd20e1ca
---

# Cluster topology (verified 2026-06-11)
- **3 rke2-servers / etcd members**: sirver (192.168.50.204), octopus (192.168.50.53), dingo (192.168.50.105)
- **Agents**: chinchilla (192.168.50.85), bonobo
- Tailscale: dingo 100.64.0.6, chinchilla 100.64.0.5, bonobo 100.64.0.4, octopus 100.64.0.3 (`*.ts.trdos.me`, resolvable only on-net)
- Ceph mons run on the 3 server nodes (host IPs, port 3300)

# Outage mechanism (2026-06-11, after PR #40 deploy + RKE2 1.34.5→1.34.7)
1. All three rke2-servers restarted near-simultaneously for the upgrade (sirver 01:37 PDT; octopus ~02:09; dingo ~03:43).
2. rke2-server exit kills containerd (child) but leaves containerd-shims/containers orphaned. containerd's CRI log copier is the **only reader** of each static-pod container's stdout/stderr pipe.
3. etcd was in a slow-request log storm (quorum degrading as peers dropped) → 64KB pipe buffer filled → etcd's zap logger blocked in `write(2)` (`anon_pipe_write` in kernel stack) → logging mutex froze the raft loop → etcd unresponsive even on localhost /health.
4. Distributed deadlock: rke2-server startup needs a quorum read from etcd within 10s (fatals: "failed to reconcile with local datastore: context deadline exceeded") → containerd never restarts → pipes never drain → all 3 etcd members frozen → no quorum.
5. Collateral: kubelets down on server nodes → ceph mons down → RBD I/O hangs cluster-wide (jbd2/rbdN in D state, load ~18 from iowait, CPU idle).

# Diagnosis evidence/commands
- Pipe-block proof: `grep -q pipe_write /proc/<etcd-pid>/task/*/stack` → `anon_pipe_write+0x393`
- etcd pids at the time: sirver 1467836, octopus 3153309, dingo 2098
- etcd data healthy: 57MB/153MB, defragged 01:37, `experimental-initial-corrupt-check: true`

# Recovery (minimal, non-destructive) — CONFIRMED WORKING 2026-06-21
**Drain the pipe READER, not etcd's own fd.** etcd's `/proc/<etcd>/fd/2` is the pipe WRITE end — you cannot read/drain it; `cat` there returns 0 bytes (verified no-op, the mistake made first time). The reader holding the READ end is the **orphaned containerd-shim** left from the dead containerd. Find its read-end fd and cat THAT:
- Identify: `i2=$(readlink /proc/<etcd>/fd/2); for fd in /proc/[0-9]*/fd/*; do [ "$(readlink "$fd" 2>/dev/null)" = "$i2" ] && echo "$fd"; done` → the non-etcd hit is the shim's read end (observed: shim fd16=stderr, fd14=stdout).
- Drain persistently on all 3 nodes (quorum needs ≥2): cat the shim's read-end fds to a file via a transient unit (`systemd-run --unit=etcd-drain --collect`).
- **NixOS gotcha:** a `systemd-run` transient unit has a minimal PATH — `pgrep`/`cat`/`readlink` are NOT found (unit fails on line 1). Export `PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin` at the top of the drain script.
Draining ~40MB of backed-up log/node unblocks the write instantly → raft resumes → quorum re-forms → rke2-server's 15s retry succeeds → containerd re-adopts the SAME etcd shim and resumes consuming logs (verify `crictl ps --name etcd` + etcd CRI log mtime current) → STOP the drains (else they steal bytes from the container log). No etcd restart, no data loss. Snapshots in `db/snapshots/` are the backstop.

**2026-06-25 recurrence — SINGLE node (sirver), fixed again, + a drain gotcha that cost a cycle:** This was NOT a simultaneous restart — heavy kubectl/API churn against ONE server (tight `kubectl` loops + debug-pod create/delete while debugging an app) tipped sirver's etcd into the log-storm→pipe-fill freeze on its own. octopus+dingo held quorum so the cluster stayed up (4/5 Ready; same crashloop `failed to reconcile with local datastore: context deadline exceeded`; etcd thread in `anon_pipe_write` to fd2). **GOTCHA:** `cat <stdout-read-fd> <stderr-read-fd>` (e.g. `cat /proc/<shim>/fd/14 /proc/<shim>/fd/16`) BLOCKS reading the *empty stdout* fd and never reaches the *full stderr* fd → drains 0 bytes, no recovery. etcd's wedged thread writes to **STDERR (fd2)**, so drain the **stderr read-end DIRECTLY** (the non-etcd holder of `readlink /proc/<etcd>/fd/2`'s pipe — observed shim fd16). Doing only that: drained ~3MB instantly, `pipe_write` thread cleared, `rke2-server` active in ~35s, sirver Ready, no restart/data-loss. **LESSON: do NOT hammer one server's apiserver hard — spread kubectl across servers, avoid debug-pod churn, back off. A marginal etcd tips into this freeze under load even without a restart.**

# Post-recovery residual: wedged kernel RBD client (2026-06-21)
After etcd quorum returned, ONE server (sirver) did NOT settle: kernel libceph client looped `cephx msgr authentication failed: -13` to a SINGLE osd (osd3@octopus:6848) every ~30s → all RBD-backed volumes on that node hung (`jbd2/rbd*` + postgres D-state on do_get_write_access/jbd2_log_wait_commit), load climbed to ~66 (pure D-state iowait, CPUs idle), that node's own apiserver got slow.
- Diagnosis: NOT clock skew (NTP synced), NOT a ceph fault (HEALTH_WARN but all PGs active, 14/14 osd up; octopus/dingo clients used osd3 fine). It was sirver's CLIENT-SIDE stale cephx ticket — single node, looping forever, not self-healing.
- `ceph osd down <id>` to bump the osdmap epoch did NOT clear it (stale state is the client's mon-issued ticket, not the OSD). Low-confidence; skip next time.
- **FIX = reboot the affected node** (quorum survives on other 2/3). BUT a clean `systemctl reboot` HANGS in shutdown on the unkillable D-state RBD unmounts (network torn down first → node goes silent, never actually reboots; presents as "powered, loud, hot, no ping" for >10min). sysrq unusable once off-network → **hard power-cycle** (replicated + crash-consistent data makes it safe). Fresh boot clears it: `-13` gone, D-state 0, mounts clean, OSDs re-peer, ceph backfills to HEALTH_OK. Crashlooping cilium agents self-healed once control plane was stable.

# Lessons / follow-ups
- Never upgrade/restart all RKE2 servers simultaneously — stagger, wait for `systemctl is-active` + etcd health between nodes.
- This pipe-freeze is a generic hazard of rke2's "leave pods running" restart model whenever the supervisor dies while a static pod is logging heavily.
- Wedged kernel RBD client after a long mon outage → reboot the node (hard power-cycle if shutdown hangs on D-state unmounts); don't bother with `ceph osd down`.
- Access: reaching the cluster needs the home LAN / a subnet route to 192.168.50.0/24. The Mac on the corporate `chewielabs.com` tailnet (100.120.x, MagicDNS tailb83e4.ts.net) has NO path — cluster is on the trdos.me tailnet (100.64.0.x) / home LAN. During an outage, drive nodes by IP, not name (home DNS may be down).
- AdGuardHome runs ON this cluster → a cluster outage breaks home WiFi DNS if the ASUS router points at AdGuard's LB IP (separate DNS chip 2026-06-21). Worth a router-level fallback resolver so cluster downtime can't kill home DNS.
- The auto-approval permission gate blocks shared-state mutations (ceph osd ops, node reboot) even with in-chat "go" — needs a settings Bash allow-rule or the user runs them.
- Ceph baseline is **permanently HEALTH_WARN** and will NOT reach OK: all pools `size 3` with CRUSH failure domain `host`, but only 2 OSD hosts (octopus + sirver; dingo has none) → ~233 PGs permanently undersized. `min_size=2` is satisfied so data is fully available + survives one host loss. **User accepted 2× as-is 2026-06-21 (no good 3rd storage node) — do NOT keep proposing OSD additions / size-2 / failure-domain changes.** Cosmetic leftovers from the outage: `ceph crash archive-all` + a self-catching scrub backlog.
- PR #46 (multus): gate to merge = etcd 3/3 stable, all nodes Ready, pod churn drained, **no NEW ceph issues** (NOT HEALTH_OK — see above), nixidy manifests validated. Merging via ArgoCD does **not** restart rke2-servers (rolls the cilium agent DS staggered + a sirver-gated multus DS; etcd/apiserver are hostNetwork static pods). The only node-config touch is the `cni-dhcp` systemd daemon, scoped to sirver in phase 1 and shipped by a **manual** `pulumi up` — apply node configs one at a time, never all servers at once. Roll staged: sirver first, confirm cilium + CoreDNS + a test pod still get networking before phase 2 (drop the nodeSelectors + the sirver hostname gate). Full incident report: `~/Documents/rke2-etcd-freeze-incident-2026-06-21.md`.
