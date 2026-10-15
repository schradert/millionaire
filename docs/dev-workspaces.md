# Cloud development workspaces

One workspace per project, on the cluster, reachable from every client over the
tailnet: the repository, its devenv, a persistent home and Nix store, and the
coding agents run there; laptops, desktops, the phone and the Deck are
terminals and editors into it. Research date 2026-10-14; sources in
[Evidence](#evidence). Prior art: the Coder rollout designed for coruscant
(`docs/cluster/dev-environments.md` on its `tristan/cloud-dev-sandbox-fixes`
branch), adapted here to a tailnet-only homelab.

## 1. Decision

**Coder (Community, AGPL) on the cluster, Kubernetes workspaces from one
Terraform template per kind of project, a Nix-built workspace image, a
per-workspace Nix store volume. Zed connects over SSH. Agents run inside the
workspace.**

| Option | Verdict |
| --- | --- |
| **Coder** | Chosen. One chart plus Postgres; Keycloak OIDC login is in the free tier; templates are Terraform in this repo; `coder config-ssh` makes every workspace an SSH host for Zed, ssh, mosh-less terminals; web terminal for the phone; autostop with activity bump. Stable 2.36.x, mainline 2.38 (Oct 2026) [C1, C2]. Coder Agents are Premium and Coder Tasks are reported to leave mainline from 2.37, so we do not depend on Coder's AI features [C3]. |
| Plain StatefulSet + sshd + tailscale per workspace | Runner-up and a later add-on: every workspace a tailnet node (native ssh/mosh from Termux, no client tooling). Loses self-service, lifecycle, SSO and the web terminal, and each workspace needs a headscale key. |
| Eclipse Che | Browser-first, devfiles, needs OIDC on the API server; Zed over SSH is not a documented path [A1]. |
| DevPod | Client-only (no SSO, no central lifecycle); upstream quiet since 2025 (last release v0.6.15, 2025-03), a community fork carries it [A2]. |
| Ona (Gitpod) | Control plane is Ona's SaaS; self-hosting is the enterprise "Flex" product; left Kubernetes [A3]. |
| Daytona | Open repository archived; pivoted to agent sandboxes [A4]. |

## 2. What is deployed

```text
client ──tailnet──▶ AdGuard (*.trdos.me → relays 100.64.0.4/.5) ──▶ internal Gateway
   │                                                                 │ HTTPRoute coder.trdos.me (no timeout)
   │  coder CLI / browser / Zed (ssh ProxyCommand: coder ssh --stdio) ▼
   └──────── WireGuard over DERP-over-WebSocket ─────────────▶ coderd (development) ── CNPG `coder`
                                                                   │ Terraform (kubernetes provider, Role in `workspaces` only)
                                                                   ▼
                       namespace workspaces: Deployment + PVC home (20Gi) + PVC nix (50Gi), per workspace
                         init `seed` (image store → nix volume) → agent dials coder.trdos.me
                         → Bifrost bifrost.ai.svc:8000 (allowed by the ai namespace policy)
```

- **Control plane** (`nixidy/apps/development/coder/`): Coder 2.36.7 in
  namespace `development`, `https://coder.trdos.me` on the internal Gateway
  only, Keycloak client `coder`, database `coder` on CNPG (B2 backups like every
  CNPG cluster). Coder does its own auth (the CLI and the agents use its API),
  so it is not behind oauth2-proxy. DERP is forced over WebSockets and the
  route has no request timeout (agents and tunnels are long-lived WebSockets).
- **Bootstrap Job** (hash-named, runs after coderd): the first owner `admin`
  (password generated in-cluster, pushed to Bitwarden `coder/admin-password`),
  `tristan` as an OIDC owner (the first Keycloak login links by email), and
  every template under `templates/` pushed with its variables (a version is the
  hash of files + variables, pushed once).
- **Template `devenv`** (`templates/devenv/main.tf`): parameters repository
  (default this repo), CPU, memory, home and Nix volume sizes. Pod pinned to
  the non-etcd big nodes (`falcon`, then `axolotl`), tolerating their soft
  desktop taint. Startup: bash + direnv hook, nix-direnv, opencode config for
  Bifrost, `git clone` + `direnv allow` once, a detached zellij session named
  after the project. Apps: web terminal, SSH helper, port forwarding, a Zed
  link (`zed://ssh/coder.<ws>/…`). Autostop 8h, bumped 1h per activity.
- **Image** `harbor.trdos.me/library/workspace` (`apps/workspace/image.nix`,
  published by the in-cluster image-publish workflow): user `coder` (1000),
  single-user Nix (unsandboxed, `filter-syscalls = false`), git, gh, tea,
  nix, devenv, direnv, nix-direnv, zellij, tmux, helix, lazygit,
  ripgrep/fd/fzf, claude-code, opencode. 1.8 GiB store.
- **Namespace `workspaces`**: ResourceQuota (24 CPU / 64 GiB requests, 1 TiB
  storage, 1 GPU, no LoadBalancers), LimitRange defaults, Cilium default-deny
  ingress (agents dial out; nothing dials in, workspaces cannot reach each
  other).

## 3. Nix store strategy

| Option | Verdict |
| --- | --- |
| **Per-workspace store volume, seeded from the image** | Chosen. `/nix` is a ceph-block PVC. The init container `workspace-seed` copies image store paths that are missing, `nix-store --load-db`s the toolchain closure and roots it (`gcroots/workspace-toolchain`), so `nix-collect-garbage` in the workspace never removes the toolchain. First seed ≈12 s on falcon; later images add only new paths. Builds and devenv shells persist across restarts and node moves. |
| Host nix-daemon socket + host `/nix` (nodes are NixOS) | Rejected for now: the daemon's indirect GC roots point into the pod's home, which the host cannot see, so the host's GC collects workspace shells; the pod is tied to a node; it needs hostPath. Worth revisiting for a falcon-only "builder" workspace. |
| Shared RWX `/nix` on CephFS | Rejected: Nix's SQLite DB and locks over a network FS, and one store for all workspaces. |
| Image `/nix` only (coruscant) | Rejected: every restart re-substitutes the devenv closure into the container layer (and overlayfs copy-up on these nodes is the known slow path). |

Substituters: cache.nixos.org, nix-community, devenv. The personal attic cache
on sirver is not reachable today (falcon's builds log `sirver:8199` connection
refused) and is out of scope; add it to the image's `nix.conf` when it is back.
Heavy builds: the workspace builds with its own CPU (falcon: 32 cores); remote
builders (falcon, the nodes) need a per-workspace builder key, a later step.

## 4. Cost on this cluster

| Item | Requests | Notes |
| --- | --- | --- |
| coderd | 250m CPU, 512 MiB (limit 2 GiB) | plus CNPG `coder` (5 GiB volume) |
| one workspace (defaults) | 4 CPU, 8 GiB; 20 + 50 GiB volumes | volumes are thin RBD; Ceph pool size 2, so the used bytes count twice; 22.6 TB raw free |
| stopped workspace | volumes only | pod deleted by autostop |
| quota ceiling | 24 CPU / 64 GiB / 1 TiB | `workspaces` ResourceQuota |

Placement: falcon (32 cores, 64 GiB, RTX A2000, 0.3 cores requested today) and
axolotl (8 cores, 32 GiB) are the only non-etcd nodes with room; the etcd
nodes stay out because build bursts there were what flapped etcd before
(octopus, 2026-10-11). falcon is also a desktop: a reboot moves or stops the
workspace (the RBD volumes follow the pod).

## 5. Security model

- **Reach**: `coder.trdos.me` exists only on the tailnet (internal Gateway via
  the relays); workspaces have no Service, no ingress, no LoadBalancer.
- **Identity**: Keycloak OIDC for people; `admin` is break-glass (Bitwarden).
  Coder owners can open any workspace (Community has no audit log or template
  RBAC; that is Premium [C4]).
- **Pods**: uid 1000, non-root, RuntimeDefault seccomp, no ServiceAccount token,
  no hostPath, no privilege; Nix runs unsandboxed inside that container.
- **Network**: ingress default-deny; egress is open (internet for git and
  substituters, and the LAN). An egress allowlist (internet minus RFC1918,
  plus Bifrost, DNS and the Gateway VIP) is the next hardening step once
  Hubble flows are replayed.
- **AI credentials**: in-cluster Bifrost needs no key (`enforce_governance_header`
  off), so a workspace can spend the provider keys; per-workspace Bifrost
  virtual keys are the fix when there is more than one user. Claude Code's
  claude.ai login, `gh`/`tea` tokens and git credentials live in the home
  volume.

## 6. Agents in workspaces

- **Claude Code**: logs in with the claude.ai subscription (`claude` once per
  workspace, token in the home volume). That keeps **Remote Control** usable:
  it is blocked as soon as `ANTHROPIC_BASE_URL` points at a gateway [P1].
  `claude-bifrost` (alias in `~/.bashrc`) runs it through Bifrost's
  Anthropic-compatible `/anthropic` endpoint instead [B1, P2] (Claude models
  only: Anthropic does not support other models behind Claude Code [P2]).
  Multi-agent: subagents, and experimental agent teams
  (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) with split panes in **tmux**
  (in the image; zellij is not supported, open requests #24122/#31901) [P3].
- **opencode**: `~/.config/opencode/opencode.json` gets a `bifrost` provider
  (in-cluster `/v1`, models `<provider>/<model>`); pick per task with
  `/models` or per-agent `model:` in the project's opencode config. `opencode
  serve`/`web` and `opencode attach` give a long-running backend that several
  terminals (or a phone browser) attach to [O1].
- **Per-task models** (Bifrost names): planning/review `anthropic/claude-sonnet-4-5`
  or `openai/gpt-5`; bulk edits `gemini/gemini-2.5-pro`; once the GPU models
  return, local `ollama/...` for cheap or private work. Nothing answers until
  the provider keys exist (see docs/ai-guide.md).
- **Orchestration like this session**: Claude Code in the workspace with
  subagents/agent teams in tmux; or several agents in parallel worktrees via
  zellij tabs, Claude Squad (tmux) or tuios `fan` [T1, T2].

## 7. Zed

- **Remote development**: Zed runs its UI locally and a headless server on the
  workspace (static musl build, downloaded or uploaded with
  `upload_binary_over_ssh`); language servers, tasks and terminals run remotely
  [Z1]. It uses the local `ssh` and `~/.ssh/config`, so `coder config-ssh`
  (ProxyCommand `coder ssh --stdio`) makes `zed ssh://coder.<ws>/home/coder/<repo>`
  work (the ProxyCommand path is inferred, not documented by Zed).
- **Agents**: external agents (Claude Agent, `opencode acp`) run over SSH in
  remote projects [Z2], so they use the workspace's logins and Bifrost.
- **Collaboration**: the collab server is not self-hostable in practice. Issue
  #8260 is open, there are no docs, sign-in is GitHub only, and clients talk to
  collab.zed.dev [Z3, Z4]. Hosted channels and project sharing work, with the
  project's contents going through Zed's servers; external agents are not
  available in shared projects (code comment in `agent_server_store.rs`) [Z2].
  Recommendation: several of your own machines on one project do not need
  collab (each opens the same workspace over SSH); for pairing with people use
  Zed's hosted channels only for repositories you are fine relaying, otherwise a
  shared zellij session (`zellij attach <project>`, or `zellij web` with a
  read-only token) [T3].

## 8. Terminal workspace

- **zellij** stays the daily driver (configured in `modules/zellij`, layout
  `project`); 0.44+ adds `zellij attach https://…` remote attach, read-only web
  tokens and a scriptable `zellij action` CLI; 0.45.1 is current [T3]. Every
  workspace starts a detached session per project.
- **tmux** is in the image for Claude Code agent teams' split panes and Claude
  Squad.
- **tuios** (Go/Bubble Tea, v0.9.3 on 2026-10-14, pre-1.0, in nixpkgs) is a
  terminal window manager with a session daemon, an SSH server mode and an
  agent layer (status per pane, an approval inbox, `fan` across worktrees,
  `tmux-shim` so Claude Code's teammates open as tuios panes) [T1]. It cannot
  attach to tmux or zellij sessions; it is not intercompatible beyond the shim.
  Worth a trial as the agent dashboard, not as the multiplexer.
- Managing agents from the terminal: `coder ssh <ws>` → `zellij attach
  <project>`; one tab per agent (claude, opencode) per worktree; Claude Code's
  `/agents` and background tasks for its own fleet.

## 9. Phone (Pixel) and Deck

| Path | Works today | Notes |
| --- | --- | --- |
| Claude app → **Remote Control** of the workspace's Claude Code | yes, with the claude.ai login | `claude remote-control` in the workspace (server mode, QR code); needs a subscription and outbound internet, not a gateway [P1] |
| Browser → **Coder web terminal** | yes | `https://coder.trdos.me` over the tailnet → workspace → Terminal → `zellij attach <project>` |
| Browser → **`opencode web`** | via `coder port-forward` or a Coder app | set `OPENCODE_SERVER_PASSWORD`; there is no official opencode mobile app [O1] |
| **Termux** + ssh | needs a jump | Coder's SSH needs the `coder` CLI as ProxyCommand; the Linux arm64 build is untested in Termux. Native tailnet SSH arrives with the sshd+tailscale add-on (§1 runner-up) |
| Happy (MIT, Android app, self-hostable relay) | not set up | wraps the stock `claude` CLI [M1] |
| code-server in the browser | not yet | next template PR (needs a path or wildcard app route) |

Steam Deck (desktop mode): the same as a Linux desktop (`coder` CLI + Zed or
a terminal), or the browser.

## 10. Clients

| Client | Connect |
| --- | --- |
| falcon, axolotl (NixOS) | `coder login https://coder.trdos.me`, then `ssh coder.<ws>` / Zed (`modules/coder.nix` writes the `coder.*` SSH block, so no `config-ssh`). **Gap found**: both are now cluster nodes with `accept-dns=false`, so `*.trdos.me` does not resolve on them (falcon's resolver is 1.1.1.1); they need split DNS for `trdos.me` → 100.64.0.1 |
| morgenmuffel (personal Mac) | as above once its headscale tailscaled is deployed |
| millionaire (work Mac) | headscale is a userspace tailscaled behind `trdos` (SOCKS 1055 / CONNECT 1056). The Go CLI honours `HTTPS_PROXY` (CONNECT), so `trdos coder …` and a ProxyCommand of `trdos coder ssh --stdio …` should work; unverified |
| Pixel, Deck | §9 |

## 11. Work Mac (`millionaire`) redeploy

The darwin config already enables Zed, zellij (no auto-start), wezterm,
opencode, claude-code and the userspace headscale tailscaled (`modules/tailnet.nix`).
Workspaces are added by `modules/coder.nix` (merged, not deployed):

1. The `coder` CLI (nixpkgs 2.36.6; server 2.36.7) and an SSH block for
   `coder.*` with `ProxyCommand trdos coder ssh --stdio --ssh-host-prefix
   coder. %h` on work Macs (plain `coder` elsewhere). Evaluated for
   millionaire and morgenmuffel; falcon's home-manager path builds. Zed needs
   no settings: `zed ssh://coder.<ws>/home/coder/<repo>` uses that block.
2. Build without loading this Mac: evaluate and build the closure on
   morgenmuffel (same aarch64-darwin, already a builder), copy it over, then
   switch locally: `nix build .#darwinConfigurations.millionaire.system` on
   morgenmuffel, `nix copy --to ssh-ng://<work mac>` and
   `darwin-rebuild switch --flake .#millionaire` here (substitutes everything).
3. One-time: `trdos coder login https://coder.trdos.me`, `coder config-ssh`.

## 12. Next steps

1. Deploy the client module with the next host deploys; split DNS for
   `trdos.me` on falcon/axolotl.
2. Bifrost provider keys (docs/ai-guide.md), then `claude-bifrost` and
   opencode's `bifrost` provider answer from workspaces.
3. code-server or `opencode web` as a Coder app; a GPU parameter (falcon's A2000).
4. Egress policy for `workspaces`; per-workspace Bifrost virtual keys.
5. sshd + tailscale add-on for native tailnet SSH/mosh (Termux).

## 13. Verification (2026-10-15)

- `tristan/millionaire` created from `devenv` by the `admin` owner; pod on
  falcon in under 2 minutes (image pull included), seed ≈12 s.
- From falcon, plain OpenSSH with a `coder ssh --stdio` ProxyCommand (the CLI
  in a container, since falcon cannot resolve `*.trdos.me` yet): login shell as
  `coder`, nix 2.34.8, Claude Code 2.1.292, opencode 1.18.35, devenv 2.4.0,
  the repository cloned, zellij session `millionaire` running, Bifrost
  reachable in-cluster (answers; no provider keys), `/nix` 49 GiB and home
  20 GiB volumes mounted.
- This repository's devenv builds in the workspace (`direnv exec .`, 221 s
  cold, store 8.8 GiB).
- Fixed on the way (each its own PR): a user created before their first login
  is dormant and its agents get 401 (bootstrap activates it); the agent's
  resource monitor needs `/etc/os-release`; Cilium matches Bifrost's pod port
  8080, not the Service's 8000; Nix's builder seccomp filter refuses chmods
  that keep the setgid bit fsGroup puts on volume directories
  (`filter-syscalls = false`).
- Not verified: the Keycloak browser login (needs your password), Zed from a
  desktop, the work Mac's `trdos` path, the phone paths. One container
  connection through the bonobo relay (100.64.0.4) timed out while chinchilla
  (100.64.0.5) answered; host curl through both worked.

## Evidence

- [C1] Coder releases and channels: <https://coder.com/docs/install/releases>, chart index <https://helm.coder.com/v2/index.yaml>
- [C2] Coder networking (DERP, WebSockets): <https://coder.com/docs/admin/networking>; pricing (OIDC in Community): <https://coder.com/pricing>
- [C3] Coder Tasks / Agents: <https://coder.com/docs/ai-coder/tasks>, <https://coder.com/docs/ai-coder/agents>
- [C4] Premium features (IdP sync, audit): <https://coder.com/docs/admin/users/idp-sync>
- [A1] Eclipse Che: <https://github.com/eclipse-che/che/releases>
- [A2] DevPod: <https://github.com/loft-sh/devpod/releases>
- [A3] Ona: <https://ona.com/stories/we-are-leaving-kubernetes>
- [A4] Daytona: <https://github.com/daytonaio/daytona>
- [Z1] Zed remote development: <https://zed.dev/docs/remote-development>
- [Z2] External agents and ACP over SSH: <https://zed.dev/docs/ai/external-agents>, <https://github.com/zed-industries/zed/commit/99102a84fa30b235f6e383b20246a96f5a6a103f>, <https://github.com/zed-industries/zed/blob/main/crates/project/src/agent_server_store.rs>
- [Z3] Collab self-hosting: <https://github.com/zed-industries/zed/issues/8260>, <https://github.com/zed-industries/zed/blob/main/crates/collab/README.md>
- [Z4] Zed authentication (GitHub): <https://zed.dev/docs/authentication>; collaboration: <https://zed.dev/docs/collaboration/overview>
- [P1] Claude Code Remote Control: <https://code.claude.com/docs/en/remote-control>
- [P2] Claude Code LLM gateways: <https://code.claude.com/docs/en/llm-gateway>, <https://code.claude.com/docs/en/llm-gateway-connect>
- [P3] Claude Code agent teams: <https://code.claude.com/docs/en/agent-teams>; zellij requests <https://github.com/anthropics/claude-code/issues/24122>
- [B1] Bifrost Anthropic endpoint: <https://docs.getbifrost.ai/integrations/anthropic-sdk>
- [O1] opencode server/web/attach: <https://opencode.ai/docs/server/>, <https://opencode.ai/docs/web/>, <https://opencode.ai/docs/cli/>
- [T1] tuios: <https://github.com/Gaurav-Gosain/tuios>, tmux shim <https://github.com/Gaurav-Gosain/tuios/blob/main/docs/TMUX_SHIM.md>
- [T2] Claude Squad: <https://github.com/smtg-ai/claude-squad>
- [T3] zellij releases: <https://github.com/zellij-org/zellij/releases>
- [M1] Happy: <https://github.com/slopus/happy>
