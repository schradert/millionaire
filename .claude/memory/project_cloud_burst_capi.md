---
name: project-cloud-burst-capi
description: "Decided architecture for cloud-burst worker autoscaling — scoped CAPI + CAPH with dataSecretName bootstrap bypass, NixOS snapshot, no CCM"
metadata:
  node_type: memory
  type: project
  originSessionId: 51a8160d-742c-4292-902c-aaae3926c374
---

Decision (2026-06-10): cloud-burst node autoscaling uses **scoped Cluster API**, not plain
Cluster Autoscaler-Hetzner. Chosen because multi-provider price-shopping is a design goal
(Hetzner/Linode/Scaleway/Vultr have live CAPI infra providers; OVH has none — but plain CA does).

Key architecture facts (research-verified, sourced in the plan):
- CAPRKE2 (RKE2 bootstrap provider) is unusable: unconditional imperative installer in its
  cloud-init AND workers hard-depend on a CAPRKE2-managed RKE2ControlPlane (cannot join an
  existing RKE2 cluster on any OS). Bypass instead: `bootstrap.dataSecretName` (first-class
  CAPI field) with hand-authored NixOS-respecting cloud-init + `/run/cluster-api/bootstrap-success.complete` sentinel.
- Worker-only/external-control-plane CAPI: `controlPlaneRef` omitted; pre-created
  `millionaire-kubeconfig` Secret is honored; `ControlPlaneInitialized` stays false forever =
  cosmetic. Home nodes can never be CAPI Machines (no infra API for owned hardware; BYOH is
  kubeadm-only/unmaintained, Metal3 needs BMCs). CAPI boundary = cattle (cloud VMs) only.
- No hcloud-cloud-controller-manager: workers self-set `kubelet-arg: provider-id=hcloud://<id>`
  from Hetzner metadata; CAPI deletes Node objects on machine deletion. CCM in a hybrid cluster
  risks deleting home Node objects (foreign-node lifecycle).
- Install via cluster-api-operator (declarative provider CRs, fits nixidy); cert-manager
  prerequisite already deployed. Bootstrap-cluster/pivot dance unnecessary — home cluster is
  the management cluster.
- Connectivity: RKE2 servers join tailnet; workers pin sirver→tailnet IP in /etc/hosts
  (MagicDNS stays off). Headscale preauth key for workers is reusable+ephemeral (ephemeral ⇒
  free peer cleanup). Image: nixpkgs image framework (nixos-generators archived 2026-01),
  BIOS-bootable for Hetzner x86 ([[project-hetzner-image-strategy]]), uploaded with label
  `caph-image-name=cloud-worker` (CAPH matches by label). Snapshots are hcloud-project-scoped —
  upload must use the dedicated "millionaire-capi" project token.
- Top open risk: Cilium routingMode=native across the tailnet ([[project-cilium-l2-native-routing-bug]]);
  plan phase 2 has a datapath spike before any cluster-wide Cilium change.

Plan file: ~/.claude/plans/trying-to-devise-a-wobbly-wadler.md (full phases + risks).
Status (2026-06-11): stacked PR series COMPLETE, all 7 open for review:
#37→#38→#39→#41→#42→#43→#44 (branches cloud-burst/00..06, each based on the previous).
Runbook: docs/cloud-burst.md (on the 06 branch). Deploy gates: merge PR #32 first
(nixidy render), create millionaire-capi hcloud project + `pulumi config set --secret
hcloudCapiToken` (console-only step), pulumi up from LAN, datapath spike before CAPI PRs
apply. Not verified from off-LAN session: image build (needs home builders), live deploys.
Series detail — #37 (hyena node extraction from
snapshot/pre-pr-split-20260610; pulumi state alignment), #38 (tailnet: tailnet.nix module,
static 10.42.0.0/16 route instead of accept-routes on home nodes, headscale policy
allow-all+tag:cluster+autoApprovers, pulumi keys incl. ephemeral worker key + rke2 token
mirror + sirver IP capture), #39 (cilium: directRoutingSkipUnreachable, devices+=eth0,
L2 policy excludes node.trdos.me/burst). Branch naming cloud-burst/NN-*, each PR based on
the previous. Worker design decision: rke2 server URL uses sirver's tailnet IP directly
(no /etc/hosts pin needed — RKE2 token CA-hash pinning makes hostname irrelevant).
Remaining: 03-worker-image (make-disk-image like static/hetzner-image.nix, config-only
deploy node, hcloud-upload-image with caph-image-name label), 04-capi-operator,
05-capi-cluster, 06-autoscaler+runbook. Gotchas hit: main had latent breaks (hyena config
unlanded + pulumi state divergence; home-manager khal/vdirsyncer/opencode drift; multus
chart republished upstream — re-staged per its own header; homepage render break = open
PR #32's fix, full env render blocked until #32 merges).
