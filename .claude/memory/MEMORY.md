# Millionaire Project Memory

## Project Structure
- Nix flake project using `canivete` framework (`canivete.lib.mkFlake`)
- Dev shell: native devenv (`devenv.yaml` + `devenv.nix` + `use devenv` in `.envrc`)
- Pulumi for infrastructure, entered via dev shell: `cd pulumi && pulumi up --yes`
- SOPS/age for secrets in `secrets/sops/default.yaml`
- Nodes: `sirver`, `dingo`, `chinchilla`, `bonobo`, `octopus` (all NixOS, RKE2 cluster), `piper` (RPi, commented out - no kexec support)
- Sub-project devenvs: `esp32-s3/` and `org-bridge/` each have their own `devenv.yaml`/`devenv.nix`/`.envrc`
- [falcon ESP32 build host + attached boards](project_falcon_esp32_build_host.md) — NixOS PC at 192.168.50.215
- [nixidy render validation + hook-cascade gotchas](project_nixidy_render_validation.md) — validate before committing

## Key Files
- `pulumi/millionaire/nixos.py` - NixOS deployment via nixos-anywhere
- `pulumi/__main__.py` - Pulumi entry point
- `flake.nix` - Flake config with 30+ inputs
- `modules/darwin.nix` - macOS config
- `modules/nixos.nix` - Base NixOS config

## Solved: "Too many open files" on remote NixOS deploy
- Root cause: Remote NixOS kexec installer SSH sessions default to ulimit 1024, too low for 2000+ derivation builds
- Solution: Split nixos-anywhere into phases, use `prlimit` on remote PID 1/sshd/nix-daemon between kexec and install
- See [nixos-deploy-fix.md](nixos-deploy-fix.md) for details

## Kubernetes Access
- Fast method (preferred): `export KUBECONFIG=$(mktemp) && ssh -i ~/.ssh/personal sirver sudo cat /etc/rancher/rke2/rke2.yaml | sed 's/127\.0\.0\.1/sirver/' > $KUBECONFIG` then use `kubectl` directly
- SSH key: `~/.ssh/personal` (required for sirver access)
- Nix method (slow, re-evaluates flake): `nix run .#legacyPackages.aarch64-darwin.nixidyEnvs.aarch64-darwin.prod.config.build.scripts.kubeconfig --no-pure-eval -- <kubectl args>`

## User Preferences
- **Declarative over imperative**: Always configure things in Nix/code rather than running imperative kubectl commands. Figure out the right config option instead of running ad-hoc commands.
- [Concise config entries](feedback_concise_config.md)
- [Module system over centralized config](feedback_module_system.md)
- [Prefer generated themes over pre-made](feedback_generated_themes.md)
- [Ask before acting on ambiguous statements](feedback_clarify_before_acting.md)
- [ArgoCD sync method and namespace](feedback_argocd_sync.md)
- [Reuse existing KUBECONFIG in session](feedback_kubeconfig.md)
- [Pulumi runs are manual only](feedback_pulumi_manual.md)
- [Use nixidy resource overrides, not chart patches](feedback_nixidy_resource_overrides.md)
- [Lazy image builds — no building on devshell entry](feedback_lazy_image_builds.md)
- [No manual secret creation — everything automated](feedback_no_manual_secrets.md)
- [Prefer bun over npm for JS/TS](feedback_prefer_bun.md)
- [Prefer Rust for new bespoke services / scripts](feedback_prefer_rust_for_new_services.md)
- [Always use devenv for tools, never nix run/comma](feedback_devenv_tools.md)
- [direnv exec handles git hooks — never invoke pre-commit directly](feedback_direnv_for_hooks.md)
- [No "Generated with Claude Code" footer in PR bodies](feedback_no_claude_code_footer.md)

## Known Issues
- [GitOps health: app-of-apps seeded 2026-06-24; OutOfSync is cosmetic SSA-defaulting](project_gitops_health.md) — fix via ignoreDifferences not blanket-sync; pre-existing crashloops (ceph-csi/CNPG/oauth2-proxy) are the real work; gap-3 render drift already fixed by #56
- [RKE2 etcd pipe-freeze outage 2026-06-11: topology, mechanism, recovery](project_rke2_etcd_pipe_freeze_outage.md) — 3 servers: sirver/octopus/dingo; never restart all servers at once
- [CoreDNS MagicDNS search-domain hijack](project_coredns_magicdns_search_hijack.md) — ts.trdos.me leaks into pods, collides with *.trdos.me wildcard under ndots:5 → external DNS resolves to gateway VIP; fix = kubelet resolv-conf (PR #47)
- [hyena AdGuard + tailnet DNS — DEPLOYED](project_hyena_adguard_dns.md) — headscale pushes AdGuard to clients, nodes accept-dns=false; Cilium pool=10.0.0.0/8 (NOT RKE2 10.42); hyena IS deployable (gate was stale); deploy nodes via `-J root@178.104.61.137` jump
- [Internal gateway native tailnet IP via bonobo relay — DEPLOYED #64](project_internal_gateway_tailnet_relay.md) — systemd-socket-proxyd on bonobo (100.64.0.4) fronts the gateway; AdGuard `*.trdos.me→100.64.0.4`; replaces the .241/32 subnet route + inert pod front; ArgoCD-orphan + gateway-OutOfSync gotchas
- [Node config deployed from cloud-burst rebase, NOT main](project_node_config_cloud_burst_base.md) — live nodes run May23 nixpkgs + tailnet (no committed branch has it); deploying main removes tailscale. Node-side fixes belong on the cloud-burst base (agitated-hoover session). Handoff: ~/Documents/dns-multus-cloudburst-handoff.md
- [Cilium L2 + native routing source IP bug](project_cilium_l2_native_routing_bug.md)
- [No untested infra changes](feedback_no_untested_infra_changes.md)
- [Pulumi: never reinstall live cluster nodes — target hyena work explicitly](feedback_pulumi_never_reinstall_cluster_nodes.md)
- [Hetzner x86 = BIOS only; use golden-image strategy, not nixos-anywhere](project_hetzner_image_strategy.md)

## Productivity Stack
- [Org-mode productivity stack architecture](project_org_productivity_stack.md)

## Cloud Burst Autoscaling
- [Scoped CAPI architecture decision](project_cloud_burst_capi.md) — CAPI+CAPH with dataSecretName bypass, no CAPRKE2, no CCM; plan in ~/.claude/plans/trying-to-devise-a-wobbly-wadler.md

## Tool Installation
- **Never use brew** for CLI tools. Use `, <tool>` (comma command) which auto-downloads and runs via nix. E.g. `, swaks --help`

## PR Split (2026-06-11)
- [PR-split outcome: what landed, what's staged, snapshot audit trail](project_pr_split_2026_06.md) — multus/music-assistant STAGED; snapshot branch kept
- [Worktree commit mechanics + hook gotchas](project_worktree_commit_mechanics.md) — why commits were blocked for weeks; per-worktree hook recipe

## Dev Workflow Notes
- **ALWAYS run CLI tools via the dev shell**: `direnv exec . <tool> <args>` or `nix develop --no-pure-eval --command <tool> <args>` — this includes b2, pulumi, kubectl (via kubeconfig script), and any other tools not in the base system
- For nixidy switch: run from repo root via direnv so that hooks/treefmt are handled: `direnv exec . nix run .#legacyPackages.aarch64-darwin.nixidyEnvs.aarch64-darwin.prod.config.build.scripts.switch --no-pure-eval`
- nixos-anywhere uses custom fork: `github:schradert/nixos-anywhere`
- Stale pulumi locks: `pulumi cancel --yes`
- Python f-strings with bash: `${{...}}` produces literal `${...}`
- [Background-task reaping — detach long-lived procs](project_background_task_reaping.md) — `run_in_background` gets killed fast; use `( nohup … & )`, reparents to launchd
