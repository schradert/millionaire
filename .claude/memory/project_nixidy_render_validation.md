---
name: nixidy-render-validation
description: "How to validate nixidy changes without deploying, and the hook-cascade gotcha when touching old files"
metadata:
  node_type: memory
  type: project
  originSessionId: 3d47a54e-144c-4412-b7ca-49c68253a210
---

Render all prod manifests without applying:
`nix build .#legacyPackages.aarch64-darwin.nixidyEnvs.aarch64-darwin.prod.config.build.environmentPackage --no-pure-eval -o /tmp/nixidy-render`
Then inspect `/tmp/nixidy-render/<app>/<Kind>-<name>.yaml`. Eval errors surface ONE at a time (lazy eval) — fixing one may reveal the next.

**Why:** As of 2026-06-10 main had ~7 stacked eval/render breaks that accumulated unseen because PRs merged via GitHub (no CI render check) while local hooks were also broken. Fixed in [PR #32](https://github.com/schradert/millionaire/pull/32).

**How to apply:** Always run this render before committing nixidy changes. Also: repo-wide hooks (statix, lychee, typos, deadnix) only check changed files — touching an old file surfaces its latent lint, so expect cascading hook failures and fix them (or extend the devenv.nix exceptions) rather than fighting them. `nixidy/generated/` is refreshed by the switch flow, not by hand.

Render-cascade gotchas hit 2026-06-11 (all fixed in the working tree that day):
- Pipe-masking: `nix build ... | tail` hides the exit code — capture to a log file and `echo "EXIT: $?"` instead.
- Per-app eval isolation is impossible: canivete aggregates assertions across ALL apps, so evaluating any one app forces every app's helm IFD.
- angelnu helm charts get re-published in place: multus 7.0.0 changed content (TOFU chartHash drift) AND now bundles common 5.x, whose serviceAccount requirement breaks the chart's own hardcoded test/uninstall hook controllers — fixed via `controllers.{test,uninstall}.serviceAccount.identifier = "default"` in our values.
- nixpkgs HA lovelace modules can carry Linux-only meta.platforms (template artifact, they're plain JS) — breaks darwin eval; fix declaratively with `overrideAttrs (old: {meta = old.meta // {platforms = lib.platforms.all;};})` (done for navbar-card in home-assistant.nix). `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1` through direnv exec is unreliable — don't rely on it.
- frigate had a latent duplicate Service port (http + metrics both 5000) that newer helm rejects — ServiceMonitor now scrapes the `http` port at /api/metrics.

The raw environmentPackage build is for EVAL/type errors only — never diff it against the committed generated tree to detect drift. It skips vals (`ref+pulumistateapi://` placeholders survive) and serializes yaml differently (harbor key order, prometheus-crds field diffs, loki blank lines all look like drift but aren't). The switch script's output is the canonical comparison: in PR #46 it was byte-identical to the committed tree for every untouched app. Also from #46: nixidy's CRD generator (`fromCRD`) derives resource attr names from the CRD's `spec.names.plural` — hyphenated plurals (e.g. NAD's `network-attachment-definitions`) need `canivete.crds.<n>.attrNameOverrides."<crd metadata.name>" = "camelCaseName"`.

Deploying multus + music-assistant (2026-06-26, PRs #46/#69/#70) surfaced two more:
- **generated/ is a symlink farm — dereference when hand-copying.** The environmentPackage's per-app dirs (e.g. `multus/`) are symlinks into `/nix/store`. Copying them into `nixidy/generated/prod/` with `cp -R` commits them as symlinks (git mode 120000) → ArgoCD's repo-server rejects them **repo-wide** ("repository contains out-of-bounds symlinks. file: …/multus") → GenerateManifest fails for EVERY app → all apps go `sync=Unknown`, no reconcile (running workloads unaffected). Fix: `cp -RL` (dereference) or let the switch flow write generated/ (it writes real files). Verify with `git ls-files -s <path> | awk '$1==120000'` (must be empty).
- **angelnu multus chart image is a 404.** The chart derives the image tag from appVersion (`{{.Chart.AppVersion}}-thick`), but multus-cni publishes NO versioned 4.x `-thick` image on ghcr — only rolling `stable-thick`/`latest-thick` + old `v3.9.x`/`v4.0.0-alpha`. So `multus-cni:4.3.0-thick` is a 404 → DaemonSet init `ErrImagePull`. Pin `controllers.multus.containers.multus.image = { repository=…/multus-cni; tag="stable-thick"; digest="sha256:…"; }` (the chart's multus-installer init container reuses `.tag`, resolving to the same image). Compounds the chartHash-drift gotcha above (the 7.0.0 tarball is re-published in place periodically; re-pin both when it drifts).

Related gotchas fixed in PR #32 worth remembering if they recur:
- bjw-s app-template 4.x: `serviceAccount.<id>.enabled` (not `.create`), controller-level `serviceAccount.identifier` (not `pod.serviceAccountName`)
- canivete.crds filesets sweep ALL .yaml under prefix — set `match` to exclude kustomization.yaml
- HTTPRoutes: one rule per route (nixidy merges list elements by index); separate route per distinct rule, Gateway API longest-path precedence applies across routes (used for the kavita/komga OPDS oauth2-proxy bypass)

Reconciling generated-tree drift (diagnosed 2026-06-24, fixed in fe27f83 + 4479bb8):
A render is a pure function of (committed .nix sources + committed flake.lock). On a CLEAN tree, if the flake.lock input nodes are UNCHANGED since the last regen (diff nixhelm/nixidy/canivete/nixpkgs revs between the regen commit and HEAD), drift CANNOT be chart-version drift — charts are pinned via flake.lock. Cause is then (b) .nix edited post-regen without re-rendering → commit the re-render, OR render NON-DETERMINISM → pin the entropy source.
- jitsi-meet chart: `grep -rn randAlphaNum templates/` → SIX `default (randAlphaNum 10) .Values.X` secret fields across templates/*/xmpp-secret.yaml. Pin ALL or each component's `checksum/secret` pod annotation churns every render (spurious diff + pod restart on sync). Originally only the 4 `*.xmpp.password` were pinned; `jibri.recorder.password` and `jicofo.xmpp.componentSecret` were not. Dummies only feed the helm checksum — real values come from ExternalSecrets and the Secret data is blanked via `lib.mkForce {}`, so dummies never reach runtime. Verify determinism by rendering 2-3x and comparing per-file (read each file explicitly; a combined multi-file `grep` can reorder lines and look like a false swap).
- cilium config edits roll pods via the `cilium.io/cilium-configmap-checksum` annotation on DaemonSet-cilium + Deployment-cilium-operator (deterministic sha of the ConfigMap) — expected, not drift.
- vals-401 gotcha: the switch script runs `vals eval` over every file; without Pulumi creds it 401s and leaves `ref+pulumistateapi://` placeholders in pulumi-backed files (cloudflared ConfigMap + DNSEndpoint-cloudflared-tunnel). That's measurement noise, not drift — `git checkout -- nixidy/generated/prod/cloudflared` before committing.
