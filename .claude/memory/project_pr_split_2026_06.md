---
name: pr-split-2026-06-outcome
description: "The 2026-06-11 working-tree split — what landed on main, what stayed staged, and the snapshot audit trail"
metadata:
  node_type: memory
  type: project
  originSessionId: 16b05f0e-d4b6-47c4-8dbb-ff3dc07bec23
---

The full uncommitted working tree (frozen as branch `snapshot/pre-pr-split-20260610`, commit b936fe5 — kept for audit) was split into 10 squash-merged PRs (#27–#31, #33–#36, #40) on 2026-06-11. #40 regenerated `nixidy/generated/prod` and is the deployment event (first complete render since generation broke; ArgoCD picks it up from main).

Key facts that outlive the session:
- **multus + music-assistant: DEPLOYED 2026-06-26** (PR #46 merged + #69 dereference-symlinks fix + #70 image-pin fix). multus DS on sirver (00-multus.conf coexists with 05-cilium.conflist via cilium `cni.exclusive=false`), NAD CRD via canivete.crds (attrNameOverrides keyed by CRD metadata.name), stock CNI paths /etc/cni/net.d + /opt/cni/bin, home-lan NAD (macvlan/br0/DHCP), `cni-dhcp` NixOS daemon deployed to sirver via deploy-rs switch (no reboot — only-cni-dhcp delta confirmed by dry-activate). music-assistant runs on sirver with eth0 (cilium) + net1 (home-lan macvlan, DHCP LAN IP). Phase 1 = sirver-gated; **phase 2 DONE 2026-06-26 (PR #71): multus DaemonSet cluster-wide on all 5 nodes** (00-multus.conf coexists with cilium everywhere via cni.exclusive=false). cni-dhcp STAYS sirver-only — the home-lan NAD is a macvlan on br0 and only sirver has br0; extend (drop the hostname gate) only when a NAD targets another node's NIC. Gotchas that cost real time — see [[nixidy-render-validation]]: the environmentPackage is a symlink farm (cp -RL when hand-copying generated/, or ArgoCD repo-server rejects out-of-bounds symlinks repo-wide → all apps Unknown); the angelnu multus chart's appVersion-derived image is a 404 (pin stable-thick@digest).
- Fidelity vs snapshot: only deletions are accidental `embedded/apps/hello-world/target/**` artifacts; all other deltas are review-driven fixes documented in the PR bodies (notably: stalwart's HTTPRoute deleted not renamed — dead oathkeeper backend; cloudflared rendered resolved — snapshot carried unresolved `ref+pulumistateapi` vals placeholders).
- The snapshot's generated tree was partially stale against its own flake.lock (frigate/prometheus/cilium-crds at older chart states) — never trust a working-tree render as ground truth; re-render and diff.
- Other sessions' PRs at the time: #32 (OPDS), #37 (snapshot-verbatim hyena dupe — superseded by #34/#35, comment posted), #38 (tailnet cluster join), #39 (cilium cloud-burst prep). [[pr-split-worktree-commit-mechanics]]
- **Stale-checkout trap**: the prek "Target of repeat operator is invalid" commit-blocker (ruff exclude `pulumi/sdks/**` glob-as-regex) is FIXED on main by #29 (commit 1661121, merged 2026-06-11). Any checkout/worktree based on ≤961e3c0 (#24) still shows it — sync/rebase past #29 instead of re-fixing; a re-fix PR would conflict. #29 also repaired statix scoping, tagref, lychee, gitleaks — patching the ruff line alone doesn't fully unblock commits on old trees. As of 2026-06-11 the primary checkout `~/Projects/millionaire` was still on 961e3c0 + the dirty pre-split tree (only ~579 local-only lines vs origin/main, all drafts subsumed by #29/#34/#35/#36/#46; snapshot branch preserves everything).
