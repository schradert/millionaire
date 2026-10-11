# Client connections

Every cluster service, and the client each host uses to reach it. The rows come from the portal catalog (`nixidy/system/portal.nix`; the rendered `catalog.json` is in `nixidy/generated/prod/dashy/ConfigMap-dashy.yaml`), plus the services on hyena (`static/hyena.nix`) and the Kubernetes API. Every hostname is `<name>.trdos.me` on the internal gateway, so it resolves and answers only over the tailnet.

Cells: **done** (the module that provides it) · **todo** (planned module or blocker) · **web** (browser only; Keycloak SSO or oauth2-proxy) · **n-a**.
Credentials: Keycloak SSO where the client speaks OIDC, otherwise a Bitwarden Secrets Manager key read with `bws-get <key>` (`modules/git.nix`). The last column names whatever creates that key.

## Hosts

| Host | OS | Profiles | Tailnet |
|---|---|---|---|
| millionaire | macOS | work, workstation | Mill's Tailscale tailnet; not on headscale (see Open questions) |
| morgenmuffel | macOS | personal, workstation | done: `modules/tailnet.nix` (host lands with the hosts workstream) |
| falcon, axolotl | NixOS | client, workstation | done: `static/tailnet-personal.nix` |
| systeamadeck | NixOS (Jovian) | client, gaming | todo: not a `personal.yaml` recipient in `.sops.yaml` |
| echidna | NixOS-WSL | pending (hosts workstream) | n/a until the host exists |
| Android | `modules/android.nix` | `base` / `homelab` / `family` sets | done: Tailscale app (docs/android.md) |

Modules are gated on `profiles.workstation.enable` (CLIs, Mac casks) or `profiles.client.enable` (Linux desktop apps) plus the OS, so a new host picks them up from its profiles alone.

## Matrix

| Service | Auth | macOS | NixOS workstations | Steam Deck | Android | Credential |
|---|---|---|---|---|---|---|
| headscale (tailnet) | preauth key | done: `modules/tailnet.nix` (personal Macs) | done: `static/tailnet-personal.nix` | todo (sops recipient) | done: Tailscale | sops `headscale/preauth-key/personal` (pulumi) |
| Kubernetes API (sirver:6443) | admin kubeconfig | done: `modules/kubernetes.nix` (kubectl, k9s, helm, cilium-cli; `kubeconfig` writes `~/.kube/trdos`) | done: `modules/kubernetes.nix` | n-a | n-a | `/etc/rancher/rke2/rke2.yaml` over ssh |
| argocd | OIDC | done: argocd CLI, `argocd-login` (SSO), `modules/kubernetes.nix` | done: same | n-a | n-a | Keycloak public client `argocd-cli` (argocd.nix) |
| argo-rollouts | oauth2-proxy | done: kubectl-argo-rollouts, `modules/kubernetes.nix` | done: same | n-a | n-a | kubeconfig |
| argo-workflows | OIDC | web | web | n-a | web | — |
| harbor | oauth2-proxy (UI); `/v2/`, `/service/`, `/api/` direct | done: `harbor-login [docker\|podman]`, `modules/kubernetes.nix` | done: same | n-a | n-a | bws `harbor/robot/secret` (pulumi `__main__.py`) |
| atuin | atuin account | done: `modules/atuin.nix` | done: `modules/atuin.nix` | done: `modules/atuin.nix` | n-a | atuin login (key on device) |
| forgejo (git) | oauth2-proxy (UI); git over https and `/api` direct | web; git over ssh/https; todo: tea/fj CLI token | web; todo | n-a | todo (GitNex) | needs a token generator |
| windmill, sveltekit-demo | OIDC / none | web | web | n-a | web | — |
| bifrost | oauth2-proxy | todo: opencode provider (blocked, see Open questions) | todo (blocked) | n-a | n-a | — |
| contextforge (mcp) | oauth2-proxy | todo: MCP entry (blocked) | todo (blocked) | n-a | n-a | — |
| librechat (chat) | oauth2-proxy + OIDC | web | web | n-a | web | — |
| promptfoo | oauth2-proxy | web | web | n-a | n-a | — |
| Kubernetes MCP | kubeconfig | done: mcp-k8s-go (read-only, context `trdos`), `modules/opencode.nix` | done: same | n-a | n-a | kubeconfig |
| actual | oauth2-proxy | web | web | n-a | web (`actual` tile) | — |
| firefly | oauth2-proxy | web | web | n-a | Waterfly (blocked by oauth2-proxy) | — |
| sure | OIDC | web | web | n-a | web | — |
| mealie | OIDC | web | web | n-a | web (`mealie` tile) | — |
| miniflux (rss) | password | done: newsboat + elfeed, `modules/feeds.nix` | done: `modules/feeds.nix` | n-a | todo (no reader in catalog) | bws `miniflux/tristan-password` (miniflux.nix) |
| baikal (cal) | Digest on `/dav.php` | done: khal + vdirsyncer, `modules/calendar.nix` | done: same | n-a | done: DAVx5 + Fossify | bws `baikal/admin-password` (baikal.nix generatedSecrets) |
| syncthing (sync) | oauth2-proxy (GUI) | todo: no hub pairing | todo: no hub pairing | n-a | done: Syncthing-Fork (pairing by hand) | hub device ID not declared |
| webdav (dav) | oauth2-proxy | n-a (clients cannot pass oauth2-proxy) | n-a | n-a | n-a | — |
| home-assistant (hass) | OIDC | done: companion cask, `modules/desktop-clients.nix` | web | n-a | done: Home Assistant | — |
| homepage, homarr, dashy, android | OIDC / oauth2-proxy | web | web | n-a | web | — |
| chirpstack, excalidraw, frigate, logseq, rclone, siyuan, zigbee2mqtt, zwave-js-ui | OIDC / oauth2-proxy | web | web | n-a | web (frigate tile) | — |
| kosync | KOReader account | n-a | n-a | n-a | done: KOReader (`eink` set) | — |
| keycloak | — | web (SSO for everything) | web | web | web | — |
| bulwark (webmail) | OIDC | web (mail clients: mail workstream) | web | n-a | web | — |
| jellyfin | OIDC | done: Jellyfin Media Player cask, `modules/media-clients.nix` | done: delfin, `modules/media-clients.nix` | done: delfin | done: Jellyfin | SSO |
| navidrome | own login | done: feishin, `modules/media-clients.nix` | done: feishin | done: feishin | done: Tempus | bws `navidrome/admin-password` (navidrome.nix) |
| immich | OIDC | done: immich-cli (`modules/media-clients.nix`); todo: API key for `immich login` | done: same | n-a | done: Immich | needs an API key generator |
| audiobookshelf | oauth2-proxy | web | web | n-a | done: Audiobookshelf | — |
| kavita, komga | OIDC | web (OPDS: docs/ereader-opds.md) | web | n-a | done: Mihon, Komelia | — |
| sonarr, radarr, lidarr, prowlarr, bazarr, autobrr, maintainerr, seerr, shoko, ryot, multi-scrobbler, maloja | oauth2-proxy / own | web | web | n-a | web | — |
| owncast, jitsi | own | web | web | n-a | todo (no Jitsi app in catalog) | — |
| music-assistant | oauth2-proxy | web | web | n-a | via Home Assistant | — |
| dvd-webdav, games-webdav | own | n-a | n-a | games: `modules/gaming/consoles.nix` (library off) | n-a | — |
| prometheus | oauth2-proxy | done: promtool (offline checks; queries via `kubectl port-forward`), `modules/kubernetes.nix` | done: same | n-a | n-a | — |
| alertmanager | oauth2-proxy | web (amtool skipped: API behind oauth2-proxy) | web | n-a | n-a | — |
| grafana, gatus, status (hyena) | OIDC / none | web | web | n-a | web | — |
| ntfy (hyena) | none (tailnet) | done: ntfy CLI; `alerts` subscriber on personal Macs, `modules/ntfy.nix` | done: CLI + `alerts` subscriber (user service) | n-a | done: ntfy | — |
| mainsail, obico, spoolman | oauth2-proxy | web; todo: orca-slicer (commented cask in `modules/default.nix`) | web | n-a | done: Mobileraker | — |
| rook-ceph, rados | own | web | web | n-a | n-a | — |
| Bitwarden (hosted, not in the cluster) | account | done: cask (`modules/desktop-clients.nix`) + Brave extension (`modules/browser.nix`) | done: bitwarden-desktop + Brave extension | done: bitwarden-desktop | done: Bitwarden | account login |
| Bookmarks (`dashy.trdos.me/bookmarks.html`) | oauth2-proxy | todo: Floccus (blocked) | todo | n-a | n-a | — |

## Open questions

- millionaire is on Mill's tailnet. Tailscale keeps one active profile at a time, so joining headscale there means `tailscale switch` by hand. Until then no `*.trdos.me` client on that Mac can connect.
- bifrost and contextforge sit wholly behind oauth2-proxy, which accepts no bearer tokens. API and MCP clients need either a direct route for `/v1` and `/servers/*/mcp` (bifrost virtual keys, contextforge JWTs) or `--skip-jwt-bearer-tokens`.
- syncthing: the hub's device ID is generated at runtime and its volume is not restored, so desktops cannot declare it as an introducer. The hub needs a pinned identity (cert/key as a generated secret) first.
- Floccus: `dav.trdos.me` is behind oauth2-proxy, and the org-stack design drops WebDAV. The alternative backend is Floccus's Git sync against forgejo, which needs a token.
