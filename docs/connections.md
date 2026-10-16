# Client connections

Every cluster service, and the client each host uses to reach it. The rows come from the portal catalog (`nixidy/system/portal.nix`; the rendered `catalog.json` is in `nixidy/generated/prod/dashy/ConfigMap-dashy.yaml`), plus the services on hyena (`static/hyena.nix`) and the Kubernetes API. Every hostname is `<name>.trdos.me` on the internal gateway, so it resolves and answers only over the tailnet.

Cells: **done** (the module that provides it) · **todo** (planned module or blocker) · **web** (browser only; Keycloak SSO or oauth2-proxy) · **n-a**.
Credentials: Keycloak SSO where the client speaks OIDC; CLIs and API clients present a Keycloak access token from `sso-token` (`modules/sso.nix`, public client `cli`, device flow; one-time `sso-token login` per host); otherwise a Bitwarden Secrets Manager key read with `bws-get <key>` (`modules/git.nix`). The last column names whatever creates that key.

## Hosts

| Host | OS | Profiles | Tailnet |
|---|---|---|---|
| millionaire | macOS | work, workstation | Mill's tailnet on the system tailscaled; headscale on a second, userspace tailscaled (`modules/tailnet.nix`), used through `trdos <cmd>` (SOCKS5 :1055, HTTP :1056) |
| morgenmuffel | macOS | personal, workstation | done: `modules/tailnet.nix` (host lands with the hosts workstream) |
| falcon, axolotl | NixOS | client, workstation | done: `static/tailnet-personal.nix` |
| systeamadeck | NixOS (Jovian) | client, gaming | done: `static/tailnet-personal.nix` (a `personal.yaml` recipient; joins once the host is switched to this config) |
| echidna | NixOS-WSL | pending (hosts workstream) | key pre-provisioned (`static/host-key.sh`, docs/node-standard.md); joins once the host exists |
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
| forgejo (git) | oauth2-proxy (UI); git over https, `/api` and `/login/oauth/access_token` direct | done: tea via Forgejo's built-in `tea` OAuth app (`tea-login`, SSO), `nixidy/apps/development/forgejo.nix`; git over ssh/https | done: same | n-a | done: GitNex (`homelab` set) | tea's OAuth token (refreshed by tea) |
| windmill, sveltekit-demo | OIDC / none | web | web | n-a | web | — |
| bifrost | oauth2-proxy (bearer) | done: opencode provider `bifrost` (plugin adds `sso-token`), `modules/sso.nix` | done: same | n-a | n-a | `sso-token` |
| contextforge (mcp) | oauth2-proxy (bearer) + OAuth virtual server; UI: Keycloak SSO | done: opencode MCP `contextforge` (`sso-token mcp https://mcp.trdos.me/servers/<id>/mcp`), `modules/opencode.nix`; live once `app-bootstrap-contextforge` is pinned | done: same | n-a | n-a | `sso-token` |
| librechat (chat) | OIDC (its own login page) | web | web | n-a | web | — |
| promptfoo | oauth2-proxy | web | web | n-a | n-a | — |
| Kubernetes MCP | kubeconfig | done: mcp-k8s-go (read-only, context `trdos`), `modules/opencode.nix` | done: same | n-a | n-a | kubeconfig |
| actual | OIDC (native; the sync clients need the bare server URL) | web | web | n-a | web (`actual` tile) | — |
| firefly | oauth2-proxy | web | web | n-a | Waterfly (`/api/v1` skips oauth2-proxy: it sends a Firefly personal access token) | — |
| sure | OIDC | web | web | n-a | web | — |
| mealie | OIDC | web | web | n-a | web (`mealie` tile) | — |
| miniflux (rss) | password | done: newsboat + elfeed, `modules/feeds.nix` | done: `modules/feeds.nix` | n-a | done: Flux News (`homelab` set) | bws `miniflux/tristan-password` (miniflux.nix) |
| baikal (cal) | Digest on `/dav.php` | done: khal + vdirsyncer, `modules/calendar.nix` | done: same | n-a | done: DAVx5 + Fossify | bws `baikal/admin-password` (baikal.nix generatedSecrets) |
| syncthing (sync) | oauth2-proxy (GUI) | done: `services.syncthing` from the folder table, hub as the only device, `modules/syncthing.nix` (the host's device ID goes in the table first: docs/manual-steps.md step 11) | done: same | n-a | done: Syncthing-Fork (only `org`; add its ID to the table) | hub identity: cert-manager `syncthing-identity`, Bitwarden `syncthing/hub/{cert,key}` |
| webdav (dav) | oauth2-proxy | n-a (clients cannot pass oauth2-proxy) | n-a | n-a | n-a | — |
| home-assistant (hass) | OIDC | done: companion cask, `modules/desktop-clients.nix` | web | n-a | done: Home Assistant | — |
| homepage, homarr, dashy | OIDC (dashy's catalog exports go through oauth2-proxy) | web | web | n-a | web | — |
| android (Obtainium pages) | none (read-only, nothing secret) | web | web | n-a | web | — |
| chirpstack, excalidraw, frigate, logseq, rclone, siyuan, zigbee2mqtt, zwave-js-ui | OIDC / oauth2-proxy | web | web | n-a | web (frigate tile) | — |
| kosync | KOReader account | n-a | n-a | n-a | done: KOReader (`eink` set) | — |
| keycloak | — | web (SSO for everything) | web | web | web | — |
| bulwark (webmail) | OIDC | web (mail clients: mail workstream) | web | n-a | web | — |
| jellyfin | OIDC | done: Jellyfin Media Player cask, `modules/media-clients.nix` | done: delfin, `modules/media-clients.nix` | done: delfin | done: Jellyfin | SSO |
| navidrome | own login | done: feishin, `modules/media-clients.nix` | done: feishin | done: feishin | done: Tempus | bws `navidrome/admin-password` (navidrome.nix) |
| immich | OIDC | done: immich-cli, `immich-login` (`modules/media-clients.nix`) | done: same | n-a | done: Immich | bws `immich/tristan/api-key` (app-bootstrap immich >= 0.18.0: the admin's key; the admin is tristan, linked by email) |
| audiobookshelf | OIDC (native) | web | web | n-a | done: Audiobookshelf | — |
| kavita, komga | OIDC | web (OPDS: docs/ereader-opds.md) | web | n-a | done: Mihon, Komelia | — |
| sonarr, radarr, lidarr, prowlarr, bazarr, lingarr, cleanuparr, autobrr, maintainerr, shoko, ryot, multi-scrobbler, maloja | oauth2-proxy / own | web | web | n-a | web | — |
| seerr | oauth2-proxy + `seerr-sso` sidecar (admin and family groups): each person gets their own Seerr account (admin group: Seerr admin; family: request only), password derived and never shown | web | web | n-a | web | key: bws `seerr/sso-key`; break-glass: the Jellyfin `admin`, Seerr user 1, on the pod port 5055 only |
| ombi | oauth2-proxy (admin, family) + Ombi's header login: one Ombi account per Keycloak user, roles from the group (ombi.nix) | web | web | n-a | web (`ombi` tile); the Ombi app cannot pass oauth2-proxy | bws `ombi/admin-password` (break-glass `ombi-admin`) |
| owncast, jitsi | own | web | web | n-a | todo (no Jitsi app in catalog) | — |
| music-assistant | oauth2-proxy | web | web | n-a | via Home Assistant | — |
| dvd-webdav, games-webdav | own | n-a | n-a | games: `modules/gaming/consoles.nix` (library off) | n-a | — |
| prometheus | oauth2-proxy | done: promtool (offline checks; queries via `kubectl port-forward`), `modules/kubernetes.nix` | done: same | n-a | n-a | — |
| alertmanager | oauth2-proxy | web (amtool skipped: API behind oauth2-proxy) | web | n-a | n-a | — |
| grafana, gatus, status (hyena) | oauth2-proxy + OIDC / none | web | web | n-a | web | — |
| ntfy (hyena) | none (tailnet) | done: ntfy CLI; `alerts` subscriber on personal Macs, `modules/ntfy.nix` | done: CLI + `alerts` subscriber (user service) | n-a | done: ntfy | — |
| mainsail, obico, spoolman | oauth2-proxy | web; todo: orca-slicer (commented cask in `modules/default.nix`) | web | n-a | done: Mobileraker | — |
| rook-ceph, rados | own | web | web | n-a | n-a | — |
| Bitwarden (hosted, not in the cluster) | account | done: cask (`modules/desktop-clients.nix`) + Brave extension (`modules/browser.nix`) | done: bitwarden-desktop + Brave extension | done: bitwarden-desktop | done: Bitwarden | account login |
| Bookmarks (`dashy.trdos.me/bookmarks.html`) | oauth2-proxy | done: Floccus in Brave (`modules/browser.nix`), git backend `tristan/bookmarks` on forgejo (see Floccus below) | done: same | n-a | n-a | bws `forgejo/tristan/floccus-token` (app-bootstrap forgejo) |

## Open questions

- millionaire: headscale runs as a second, userspace tailscaled next to Mill's, so only proxy-aware clients reach `*.trdos.me`, through `trdos <cmd>`. ssh needs `ProxyCommand nc -X 5 -x localhost:1055 %h %p`; Node CLIs (immich), GUI apps and browsers need a SOCKS proxy set per app.
- oauth2-proxy accepts `Authorization: Bearer $(sso-token)` (`--skip-jwt-bearer-tokens`, audience `oauth2-proxy`), so API and MCP clients pass it as Keycloak user `tristan` with the same `groups` checks. Apps that only take their own API keys or JWTs in `Authorization` still cannot get through (Waterfly, WebDAV clients).
- contextforge 1.0.11 accepts Keycloak tokens on `/mcp` only for a virtual server with `oauth_enabled` (`oauth_config.authorization_servers` = the realm, `resource` = `oauth2-proxy`), and resolves the user from its own database. app-bootstrap contextforge creates that server (`homelab`, every registered tool, resource and prompt), trusts the `keycloak` SSO provider for API tokens and creates tristan as an admin; Keycloak SSO for the UI comes from `SSO_KEYCLOAK_*` (`nixidy/system/ai/contextforge.nix`).
- qbittorrent.trdos.me is routed behind oauth2-proxy with a tile and a Gatus check; `credentials` in `nixidy/apps/media/qbittorrent.nix` is true (the VPN items in Bitwarden: docs/manual-steps.md).
- Direct routes that skip oauth2-proxy stay where the clients speak a protocol with its own auth: baikal `/dav.php` (Digest), navidrome `/rest` (Subsonic), komga `/opds`, firefly `/api/v1` (personal access tokens; identity headers stripped), chirpstack gRPC, harbor `/v2` (robot accounts), forgejo git, `/api` and `/tristan/bookmarks.git` (tokens; Floccus).
- syncthing: the hub's identity is now a cert-manager Secret (stable while the cluster lives, copy in Bitwarden). Its device ID is recorded as `syncthing.devices.hub.id`; the hub's sync port is the LoadBalancer `syncthing-lan` (TCP and QUIC 22000 on `192.168.50.242`, the table's `hub.lan`), which each client's hub device lists first, so LAN hosts connect directly and others fall back to global discovery and relays (the Deck needs no tailnet for this).
- syncthing folders and devices are one table (`modules/syncthing.nix`): the hub gets them from app-bootstrap syncthing (pins to `pkgs/images/app-bootstrap-syncthing`), each client from `services.syncthing` (no introducer, nothing auto-accepted: a device is accepted only through an ID in the table). `steam-input` and `ludusavi` are one way, client to hub. The Deck is LAN-only until its tailnet join lands, which Syncthing does not need.

## Floccus

Floccus syncs Brave's bookmarks through its Git backend, which can only send a username and a token over HTTPS, with a browser User-Agent. So: app-bootstrap forgejo creates the private repo `tristan/bookmarks` and a Forgejo token named `floccus` (scope `write:repository`, which Forgejo cannot narrow to one repo) and pushes it to Bitwarden `forgejo/tristan/floccus-token`; the `forgejo-floccus` route sends only `/tristan/bookmarks.git/…` straight to Forgejo, past oauth2-proxy (Forgejo still checks the token). Both exist once `app-bootstrap-forgejo` is pinned.

Brave installs the extension (`modules/browser.nix`); its settings are not managed. One-time per browser profile:

1. Floccus → add account → Git (bookmarks file in a Git repo).
2. Repository URL `https://git.trdos.me/tristan/bookmarks.git`, branch `main`, username `tristan`, password: `bws-get forgejo/tristan/floccus-token`.
3. Bookmarks file `bookmarks.xbel` (format XBEL), sync folder: the bookmarks bar or a dedicated folder; auto-sync on.

On millionaire (Mac on Mill's tailnet) Brave reaches `git.trdos.me` only through the trdos proxy (Open questions, first item).

## Client matrix

`docs/client-matrix.json` is the data behind the "trdos.me client matrix" artifact <https://claude.ai/artifact/NLrwLfre65aqUe8c1335BU>: one object per app with its hostnames, exposure, auth and the client for each type (browser, desktop, android, ios, cli, tui, mcp, extensions). A client is `provisioned: yes` only with a `where` (file:line) in this repo; anything else is `no`, and `unverified` in the note when the repo cannot confirm it. `ignored` lists machine-only hostnames with a reason.

A new route needs a matrix entry. `tools/client-matrix-lint` (pre-commit and pre-push hook `client-matrix-lint`, always run) fails when a hostname in `nixidy/generated/prod/*/HTTPRoute-*.yaml` is in no app's `hostnames` and not in `ignored`, when an `ignored` host matches no route, and when a `where` names a missing file or line. A per-user host pattern uses a placeholder (`maloja-<user>.trdos.me`). Line numbers in `where` are not re-checked, so refresh them when a cited file changes.

Republish the artifact from the file after any change: read the artifact (`Artifact` action `read`), replace the value of its `const DATA` line with the compact `apps` array of the JSON (`jq -c .apps docs/client-matrix.json`), and publish to the same URL. The page and the per-browser ticks do not change.
