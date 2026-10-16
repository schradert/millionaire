# Backlog

Index of open follow-ups, one line each, with where the details live. The README's numbered TODO list (`README.md`, "TODO" items 1-58) is the main tracker for platform work and is not restated here; items below that it already covers just point to it. State checked 2026-10-15. "Reported" means seen in a session and not re-verified when this was written.

Statuses: `open`, `in progress`, `waiting on you`, `reported`.

## Hardware

- open: sirver root disk failing (SMART impending failure, zpool DEGRADED, cordoned 2026-10-12): SSD replacement plus a guarded reinstall. It is still on nixos 26.05 / rke2 1.34.7, outside the build pool (#944) and no longer hosts attic. README 24, 33.
- open: octopus etcd SSD (`etcdHighCommitDurations`). README 25, 33, 47; `docs/manual-steps.md` section 6.
- open: osd.7 drive swap. `docs/manual-steps.md` section 5.
- open: reserve the LoadBalancer pool on the router. `docs/manual-steps.md` section 5b.

## Platform / GitOps

- done (2026-10-16): node roll to nixos 26.11 / rke2 1.34.11 on chinchilla, bonobo, dingo, octopus, with the containerd dataset on the first three and attic moved to chinchilla (#978). `docs/node-standard.md`.
- open: octopus containerd dataset (etcd leader moved, `ionice -c3`, measured first) and the kernel 7.2.9 reboots (OSD hosts: forced reboot). README 24, 55.
- open: home-manager-tristan.service fails on dingo (`~/.config/Kvantum/Base16Kvantum` is a directory from an older generation; cosmetic).
- open: Macs and nodes still pointing at `sirver:8199` pick up the chinchilla attic at their next deploy or darwin-rebuild.
- in progress: render drift (another agent is fixing it).
- done (2026-10-16, PRs #927 #934 #948 #957 #965 #969 #971): no CNPG pod runs on sirver. The module default `postgres.avoidNodes = ["sirver"]` (preferred NotIn, temporary; drop it once the root disk above is replaced) keeps new clusters off it. Replicated (instances=2, required anti-affinity): keycloak, immich, forgejo, harbor, ha, contextforge, argo-workflows, windmill, ryot, atuin, firefly, sure, mealie. Single instance, just moved: chirpstack, homarr, miniflux, autobrr, lidarr, radarr, sonarr, gatus, obico, plus coder, jellystat, prowlarr, streamystats. Immich has no barman backup (in-app dumps only), so its standby is its only DB-level copy; streamystats has no backup either. Ceph had 22 of 26.4 TB free, so the extra replicas (10 x 5Gi x 3) fit easily.
- open: Immich has daily in-app dumps on VolSync and a weekly restore check; PITR would need a barman-capable image or the Barman Cloud plugin (`nixidy/apps/media/immich.nix:107`, `docs/media-stack.md` gap 5).
- open: Pulumi state still holds the old Keycloak admin password (`pulumi/__main__.py:734`, rotated after a leak); a refresh or replace would desync it. Reported.
- open: Streamystats has no per-user sign-in path (it takes a Jellyfin password, SSO users have none), so there is no human route (`nixidy/apps/media/streamystats.nix:25`).
- open: client matrix lint (`tools/client-matrix-lint`) only checks that cited lines exist, not that they still point at the right content. `docs/client-matrix.json`.
- open: other platform work: README 1-58 (e.g. 22 network policies, 30-31 backups, 32 VolSync restore default).

## Media

- open: ListenBrainz forward needs each person's token (`nixidy/apps/media/maloja.nix:245`, `docs/manual-steps.md` section 2, `docs/media-stack.md` gap 6).
- open: Pano Scrobbler (phone) only targets the owner's Maloja (`docs/media-stack.md` gap 6).
- open: the non-owner Jellyfin play path (and Jellyfin to Ryot) was never exercised end to end (`docs/media-stack.md` gaps 3 and 6).
- reported: DVD rips: 34 folders unmatched by Radarr import (list in the Radarr bootstrap job logs and PR #924); the LOTR Fellowship and Two Towers extended folders have no recognized video file; "The Final Cut" is parsed as title "The". See `docs/dvd-rip.md`.
- reported: Bazarr job for Elf (2003) failed; the subf2m provider throws a ConfigurationError.
- reported: e2e ombi flow sometimes fails with "SQLite database is locked" (`docs/e2e.md`).
- open: metrics gaps, request front ends for music and books, Letterboxd to Ryot RSS job, minor items: `docs/media-stack.md` gaps 7-10.

## Finance & family

- open: the invite flow should create Actual and Sure accounts for new family members (`docs/invite.md`). Do not create Actual accounts for family until SimpleFIN is file-scoped; see below.
- open: Keycloak hardening so admins cannot impersonate users, and a separate admin account from the daily login.
- open: a per-app "what the admin can and can't see" doc for family.
- open: Actual's SimpleFIN secrets are server-global, not per budget file (`docs/manual-steps.md` section 15).
- open: the Firefly SimpleFIN import creates every account as an asset account, so credit cards show negative balances. Map card-type accounts to liability accounts (`nixidy/apps/finance/firefly-simplefin.php:146`).

## Workstations

- open: Steam Deck (systeamadeck) needs a deploy for its rotated Syncthing key; it was offline. Reported (`docs/manual-steps.md` section 11).
- open: work Mac (millionaire): Iru/Kandji MDM re-disables Remote Login about every 15 minutes, so it cannot be a push-deploy target. It needs a pull-based rebuild: build the closure on morgenmuffel as an aarch64-darwin builder, `nix copy`, activate. Declare morgenmuffel as a build machine in `modules/builders.nix` (not there today) and document a `rebuild-self` path. README 41, 44.
- open: audit morgenmuffel's hand-installed Homebrew casks before its next activation: `homebrew.onActivation` cleanup uninstalls any cask not declared (it bit cursor and tailscale-app on the work Mac). README 49.

## Dev tooling

- reported: statix behaves differently in agent worktrees; markdownlint and statix fail on the Mac for untouched code (`devenv.nix:281-292`).
- reported: the pre-push clippy hook needs cargo on the Mac (`devenv.nix:193-199`).
- reported: an `apps/e2e` clippy error in an unchanged file.
- reported: a failing `gitserve` test (`apps/e2e/src/gitserve.rs`).

## Waiting on user credentials

All in `docs/manual-steps.md`:

- waiting on you: Trakt client id `ryot/trakt/client-id` plus the flags (`trakt` in `nixidy/apps/media/ryot.nix`, `traktPlugin` in `jellyfin.nix`), section 13.
- waiting on you: Letterboxd `letterboxd/username` and `letterboxd/password`, enable `letterboxd-sync`, and its image pin (`pkgs/images/letterboxd-sync/pin.json`), section 13.
- waiting on you: ComicVine key for Kapowarr, and a Suwayomi extension store URL, section 14.
- waiting on you: Bifrost provider keys `ai/*/api-key`, section 2.
- waiting on you: GitHub token `github/update-bot/token`, section 3.
- waiting on you: ListenBrainz tokens (see Media).
