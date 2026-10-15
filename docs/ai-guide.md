# Using AI in the homelab

What runs, what each piece is for, and how each client reaches it. Everything
is on the tailnet (`*.trdos.me` via the internal Gateway) and signs in with
Keycloak. State as of 2026-10-14.

## The pieces

| Service | URL | For | Auth |
| --- | --- | --- | --- |
| **Bifrost** (LLM gateway) | `https://bifrost.trdos.me` (dashboard + API); in-cluster `http://bifrost.ai.svc:8000` | One OpenAI-compatible API (`/v1`) and an Anthropic-compatible one (`/anthropic`) for every model; models are `<provider>/<model>` | dashboard and public API behind oauth2-proxy (browser login, or a Keycloak bearer from `sso-token`); in-cluster calls need no key |
| **ContextForge** (MCP gateway) | `https://mcp.trdos.me`; virtual server `homelab` at `/servers/05238f180ea94c7c8c5621976aec4604/mcp` | One MCP endpoint with every registered tool server (OpenViking today) | Keycloak (UI); Keycloak bearer for MCP clients |
| **LibreChat** | `https://chat.trdos.me` | Chat UI on Bifrost's models plus ContextForge's tools | "Login with Keycloak" (`admin` group = LibreChat admin) |
| **OpenViking** | in-cluster only (`openviking.ai.svc:1933/mcp`) | Context/memory store for agents; embeddings and VLM through Bifrost | reached through ContextForge |
| **promptfoo** | `https://promptfoo.trdos.me` | Prompt and model evals, shared results | oauth2-proxy |
| **ToolHive** | operator only | Runs MCP servers as pods; none defined yet | — |
| **OpenClaw** | none (Discord) | Discord bot on Bifrost + ContextForge | scaled to 0 until its Discord token exists |
| **Coder workspaces** | `https://coder.trdos.me` | Where coding agents run (docs/dev-workspaces.md) | Keycloak |
| GPU models (ollama, vLLM) | — | Local models on falcon's RTX A2000 | disabled in `nixidy/system/ai/default.nix`; falcon now has the GPU, so they can return |

## Today's blocker: Bifrost has no provider keys

Bifrost defines `anthropic`, `openai` and `gemini` but holds no keys: a live
`/v1/models` answers "no valid keys found for provider". Until the keys exist,
every Bifrost-backed path (LibreChat's "Homelab" endpoint, OpenViking's
embeddings, opencode's `bifrost` provider, `claude-bifrost`) fails. To fix,
put the keys in Bitwarden (`ai/anthropic/api-key`, `ai/openai/api-key`,
`ai/google/api-key`) and flip `providerKeys = true` in
`nixidy/system/ai/bifrost.nix` (and `promptfoo.nix`); see docs/manual-steps.md.
Claude Code and opencode on a claude.ai subscription do not depend on this.

## Models through Bifrost

Address a model as `<provider>/<model>`, e.g. `anthropic/claude-sonnet-4-5`,
`openai/gpt-5`, `gemini/gemini-2.5-pro` (the ones the workstation opencode
config lists). `GET /v1/models` lists what the configured keys can reach. Rough
guide: Claude Sonnet for agentic coding and review, GPT-5 as a second opinion
or for planning, Gemini 2.5 Pro for very long context; local `ollama/…` once
the GPU apps are back, for cheap or private work.

## Clients

**Browser (any device on the tailnet):** chat at `chat.trdos.me`; evals at
`promptfoo.trdos.me`; MCP admin at `mcp.trdos.me`; Bifrost logs, usage and keys
at `bifrost.trdos.me`.

**Workstations (falcon, axolotl, the Macs)** — `modules/opencode.nix`,
`modules/sso.nix`:

- One-time `sso-token login` (Keycloak device flow; the refresh token stays in
  the keychain).
- **opencode**: providers `anthropic`/`openai` (API keys from sops, or the
  claude.ai login through `opencode-claude-auth`) and `bifrost` (the plugin
  `sso-bearer.js` adds a fresh Keycloak bearer per request). MCP:
  `contextforge` through `sso-token mcp`, plus context7, grep.app and a
  read-only Kubernetes server. In Zed, opencode is an agent server
  (`opencode acp`).
- **Claude Code**: `ANTHROPIC_API_KEY` from sops when the host has it
  (`modules/opencode.nix`), otherwise the claude.ai login; MCP servers from the
  same `programs.mcp` list.
- On the work Mac, homelab traffic goes through the userspace headscale
  client: prefix commands with `trdos` (curl, opencode, sso-token, kubectl).

**Workspaces (Coder):** in-cluster, no Keycloak hop.

- opencode's `bifrost` provider points at `http://bifrost.ai.svc:8000/v1`
  (written to `~/.config/opencode/opencode.json` on first start).
- Claude Code: `claude` with the claude.ai login (keeps Remote Control for the
  phone), or `claude-bifrost` for Claude through Bifrost
  (`ANTHROPIC_BASE_URL=$BIFROST_URL/anthropic`).
- Per-task models: in opencode `/models` or an agent's `model:`; in Claude
  Code `/model`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` and
  `CLAUDE_CODE_SUBAGENT_MODEL` (all Claude models).

**Phone:** the Claude app's Remote Control into a workspace's Claude Code, the
Coder web terminal, or `chat.trdos.me` (docs/dev-workspaces.md §9).

## Walkthrough

1. Ask something quick: `chat.trdos.me` → Homelab → pick a model (needs the
   keys above).
2. Code on a project: `coder.trdos.me` → create a workspace from **devenv
   project** with the repository → `coder config-ssh` on your machine →
   `ssh coder.<ws>` (or Zed `zed ssh://coder.<ws>/home/coder/<repo>`) →
   `zellij attach <repo>` → `claude` or `opencode`.
3. Keep it going from the phone: in the workspace run
   `claude remote-control`, scan the QR code with the Claude app.
4. Give agents tools: register an MCP server in ContextForge (UI or the
   bootstrap), it appears in the `homelab` virtual server for every client.
5. Compare models or prompts: a promptfoo config against Bifrost's `/v1`,
   results at `promptfoo.trdos.me`.
