# Media stack

What each media app does for sign-in, data, acquisition, requests, tracking, observability and e2e tests, as of 2026-10-15. Each row cites the nix module (`nixidy/apps/media/…`). Then come the gaps, a ranked plan, and per-app notes.

Legend:

- **OIDC**: the app's own Keycloak login. **Header**: oauth2-proxy passes the user in a header. **Gate**: oauth2-proxy admin gate in front of an app with no users of its own. **Per-user** means each Keycloak person gets their own app account.
- **VolSync**: the PVC is backed up to B2 daily (`volsync.pvcs`). **CNPG**: Postgres with barman to B2.
- Alloy ships every pod's logs to Loki, so logs are not a column. Every app gets the generic alerts: `PVCAlmostFull`, `ContainerRestartingFrequently`, `KubeJobFailed`, and `VolSyncOutOfSync` (new).

## Matrix by domain

### Movies and TV

| App | Auth | Per-user | Bootstrap | Data | Library | Acquisition | Requests | Tracking | Metrics / dash | E2E |
|---|---|---|---|---|---|---|---|---|---|---|
| Jellyfin | OIDC (SSO plugin) | yes, roles from groups | jellyfin-bootstrap (wizard, libraries, SSO, plugins: TMDb Box Sets, Webhook) | PVC + VolSync | movies, tv, dvd (ro) | Radarr, Sonarr, Sportarr | Seerr, Ombi | → Ryot (Webhook sink, new) and → each user's own Maloja (multi-scrobbler, one Jellyfin source per user); → Trakt behind `traktPlugin` | ServiceMonitor, dashboard | movie-chain, sonarr-chain, oidc-jellyfin |
| Radarr / Sonarr | Gate (`AUTH__METHOD=External`) | no (admin tool) | `app-bootstrap arr` | CNPG + VolSync | movies / tv + downloads | Prowlarr, qBittorrent | Seerr, Ombi, Ryot "Request" (new) | n/a | exportarr, dashboard; ntfy `media` (new) | integrations-arr |
| Bazarr | Gate | no | `app-bootstrap bazarr` | PVC + VolSync | movies, tv | OpenSubtitles (no account yet) | n/a | n/a | none (exportarr needs a key) | bazarr (skips) |
| Seerr / Ombi | Header via sidecar / header | yes (seerr-sso, Ombi roles from groups) | yes | PVC + VolSync | none | Radarr, Sonarr | themselves | n/a | none | seerr, seerr-sso |
| Maintainerr | Gate | no | yes | PVC + VolSync | none | n/a | n/a | n/a | none | maintainerr |
| Shoko | Gate + own login | no | yes | PVC + VolSync | tv | (anime from Sonarr) | none | none | none | mediasvc/shoko |
| Sportarr, Tracearr, Jellystat, Tdarr | see their notes below and their modules | | | | | | | | | |
| dvd-rip | Gate | no | n/a | work PVC (not backed up) | dvd (ro) | the disc drive on falcon | n/a | n/a | PodMonitor, alerts | flows_dvdrip |

### Music

| App | Auth | Per-user | Bootstrap | Data | Library | Acquisition | Requests | Tracking | Metrics / dash | E2E |
|---|---|---|---|---|---|---|---|---|---|---|
| Navidrome | Header (`preferred_username`); Subsonic API direct | by name; the bootstrap creates (non-admin) and links every scrobbling user through the trusted header | yes | PVC + VolSync | music | Lidarr | none | → multi-scrobbler's ListenBrainz endpoint with the user's own token → that user's Maloja | ServiceMonitor, dashboard | music (as the `e2e` user), lidarr |
| Lidarr | Gate | no | `app-bootstrap arr` | CNPG + VolSync | music + downloads | Prowlarr, qBittorrent | none | n/a | exportarr; ntfy `media` (new) | lidarr |
| Music Assistant | Gate (any signed-in user) | no | none | PVC + VolSync | music (ro) | n/a | n/a | none | none | proxy smoke |
| Maloja | Gate: the owner's for admins, `maloja-<user>` for that user and admins; scrobble API key-only | one Maloja per scrobbling user (sidecars, own data dir, port, key) | init container (API keys) | PVC + VolSync (all dirs) | n/a | n/a | n/a | the per-user scrobble sink; ListenBrainz forward is a TODO | none | music |
| multi-scrobbler | Gate (admin) | yes: per user a Jellyfin source, a ListenBrainz-endpoint source and a Maloja client, each source tied to its user's client | files rendered from generated secrets | PVC + VolSync | n/a | n/a | n/a | Jellyfin and Navidrome → that user's Maloja | none | music (components, plus the `e2e` user's scrobble) |

Ryot has a music type, but no integration reads Navidrome, Maloja or ListenBrainz. Music history stays in each user's Maloja.

### Books, audiobooks, comics, manga, podcasts

| App | Auth | Per-user | Bootstrap | Data | Library | Acquisition | Requests | Tracking | Metrics / dash | E2E |
|---|---|---|---|---|---|---|---|---|---|---|
| Audiobookshelf | OIDC | yes (auto-register, roles from `abs_groups`) | yes | config + metadata PVC, VolSync | audiobooks, podcasts | **Bookshelf Audio (new)**; ABS's own podcast feeds | none | → Ryot (yank + one-time import, new) | none upstream | audiobookshelf |
| Kavita | OIDC | yes (`provisionAccounts`) | yes | SQLite PVC + VolSync | books, comics, **manga (new)** | **Bookshelf (new)**, Kapowarr, Suwayomi | none | none (Ryot has no Kavita integration) | none upstream | books-kavita |
| Komga | OIDC | yes (account on first login, default non-admin roles; was link-only until #875) | yes | PVC + VolSync | comics, **manga (new)** | Kapowarr, Suwayomi | none | → Ryot (yank, new) | none (actuator needs creds) | books-komga |
| **Bookshelf / Bookshelf Audio (new)** | Gate | no (admin tool) | `app-bootstrap arr` | SQLite PVC + VolSync | books / audiobooks + downloads | Prowlarr (Readarr sync), qBittorrent | none | n/a | exportarr ServiceMonitor; ntfy `media` | integrations-bookshelf, books-bookshelf |
| **Kapowarr (new)** | Gate | no | `app-bootstrap kapowarr` | PVC + VolSync | comics + downloads | GetComics DDL, qBittorrent | none | n/a | none | integrations-kapowarr |
| **Suwayomi (new)** | Gate (`AUTH_MODE=none`) | no | env only | PVC + VolSync | manga (`media-manga`, new) | extension stores (none configured) | none | via Komga → Ryot | none | integrations-suwayomi |
| kosync (home) | own accounts | per-account | none | PVC + VolSync | n/a | n/a | n/a | KOReader progress | none | blocked (no account deletion) |

### Photos and live

| App | Auth | Per-user | Bootstrap | Data | Metrics | E2E |
|---|---|---|---|---|---|---|
| Immich | OIDC (email link) | yes | yes (API key, e2e admin) | CNPG without barman (in-app daily dump on the VolSync-backed PVC; restore verified weekly by `backup-verify-dump`) + library PVC VolSync | ServiceMonitor, dashboard | oidc-immich, upload |
| Owncast | own admin password | n/a | none | PVC + VolSync | none | planned |

### Tracking hub: Ryot

| | Before (2026-10-15 morning) | After |
|---|---|---|
| Integrations | none | Jellyfin sink (+ Jellyfin Webhook destination, PlaybackStart/Stop of movies and episodes for tristan); Audiobookshelf yank; Komga yank; Radarr and Sonarr push from the collection "Request" |
| Imports | none | Audiobookshelf (succeeded); Trakt by public profile behind the `trakt` flag |
| Out to Trakt | none | Jellyfin Trakt plugin behind `traktPlugin` (device link in Jellyfin, docs/manual-steps.md 13) |
| Letterboxd | none | no public write API: a daily robot uploads new Trakt plays through the import page, off by default (`letterboxd-sync`, docs/scrobbling.md, docs/manual-steps.md 13) |

How the bootstrap acts as tristan: impersonation links are a Ryot Pro feature, and OIDC users cannot sign in with a password. So `app-bootstrap ryot` inserts a one-use access-link row in Ryot's database and redeems it with `processAccessLink`. It logs out and deletes the row afterwards (`apps/app-bootstrap/src/ryot_wire.rs`). Integrations Ryot supports that are not wired: Plex, Emby and Kodi (not in the stack); YouTube Music, Jellyfin Push and the browser extension (Pro only); and the Generic JSON sink (a future Letterboxd-RSS job).

## Gaps, ranked

1. **Done today.** Done:
   - Acquisition for books, audiobooks, comics and manga (Bookshelf ×2, Kapowarr, Suwayomi).
   - Ryot wired to Jellyfin, ABS, Komga and the arrs.
   - The Prosody VolSync source, which pointed at a non-existent PVC and had been failing silently since 2026-06-25.
   - A VolSync out-of-sync alert.
   - ntfy for the arrs.
2. **Done today, too.**
   - Komga creates per-user accounts on first login (#875). The roles are KomgaUser's defaults, FILE_DOWNLOAD and PAGE_STREAMING.
   - e2e no longer counts an arr `UpdateCheck` notice as a failure (#859, e2e 0.12.1 and later).
3. **Plays into Ryot not exercised end to end.** The Jellyfin → Ryot sink and webhook are configured and idempotent, but no real play has gone through yet. Check Ryot's Jellyfin integration `triggerResult` after the first play.
4. **e2e coverage for the new acquirers: done (e2e 0.15.0).**
   - `integrations-bookshelf`, `integrations-kapowarr`, `integrations-suwayomi` check the wiring; `books-bookshelf` adds a public-domain author (Dostoevsky, by metadata id) to both Bookshelf instances and lists his works.
   - Kapowarr and Suwayomi have no content flow: Kapowarr needs a ComicVine key to add any volume, and Suwayomi has only the Local source until an extension store is configured.
   - Bookshelf's name search is not used: `hardcover.bookinfo.pro/search` (third party) timed out on 2026-10-15 while its id endpoints answered.
5. **Immich database backups. Done 2026-10-15.** CNPG barman stays off (the operand image lacks barman-cloud and the Barman Cloud plugin is not installed), so the backup is Immich's daily in-app dump on the VolSync-backed PVC (RPO ~1 day, no PITR). The restore is now verified: the newest dump was restored from B2 into a scratch cluster (72 tables, 233165 rows, identical to live) and `backup-verify-dump` repeats it weekly, with alerts. Procedure: `docs/pvc-and-postgres-restore.md`. Open: a barman-capable image or the plugin would give PITR.
6. **Music tracking per user. Done 2026-10-15** (see "Music scrobbling per user" below). Each declared family or admin user has their own Maloja, multi-scrobbler routes and Navidrome link. Open:
   - The ListenBrainz forward (listenbrainz.org) is still a TODO and needs each person's own token, which only they can supply.
   - Pano Scrobbler (phone) still uses the owner's Maloja route only.
   - Jellyfin plays are matched by Jellyfin username, so a person whose Jellyfin name differs from their Keycloak username scrobbles nowhere until it matches.
7. **Metrics gaps** (note: the apparent duplicate arr scrapes are not duplicates. Job `<app>` is exportarr on :9707 from the app ServiceMonitor; job `media/<app>` is the CNPG operator PodMonitor on the app's Postgres :9187. Checked 2026-10-15: 213 active Prometheus targets, none share a scrape URL, and each exportarr series exists once, so the dashboard `max()` is harmless and nothing needs removing):
   - ABS, Kavita, Komga, Maloja, multi-scrobbler, Seerr, Kapowarr and Suwayomi expose nothing.
   - Bazarr's exportarr needs a key that can't be set declaratively.
   - qBittorrent and gluetun have no exporter.
   - The candidates are qbittorrent-exporter and Gatus-based uptime alerts.
8. **Requests for music and books** have no front end. Seerr and Ombi cover movies and TV only (Ombi also lists Lidarr music; neither mentions Bookshelf, Readarr or Kapowarr). Researched 2026-10-15:
   - **Shelfmark** (`calibrain/shelfmark`, formerly Calibre-Web-Automated-Book-Downloader) is the best fit for books and audiobooks. It has a built-in multi-user request system with per-source request policies, native OIDC and proxy-header auth (so each Keycloak person gets their own account and requests), Prowlarr indexers and download clients, and hands files to Audiobookshelf or Calibre. Caveats: its README calls it "feature stable, best effort" with no roadmap; it searches and downloads itself rather than driving Bookshelf, so it would be a second acquisition path into the same library folders; it has no comics or manga.
   - **AudioBookRequest** (`markbeep/AudioBookRequest`): OIDC and per-user requests, Prowlarr, Audiobookshelf scan. Audiobooks only, no forward-auth, and admin-created accounts.
   - Comics and manga: no request front end exists for Kapowarr or Suwayomi.
   - Not deployed: it would add a second acquisition path for little gain while Bookshelf covers the admin workflow. **Recommended workflow today:** people ask the admin, who adds the book in Bookshelf (ebooks or audiobooks), the comic volume in Kapowarr, or the manga in Suwayomi; Ryot collections stay the wish list. **If requests become a need:** deploy Shelfmark behind OIDC for books and audiobooks (point its download client at qBittorrent and its output at the Bookshelf-managed folders so Kavita and Audiobookshelf pick them up), and leave comics and manga admin-driven.
9. **Letterboxd → Ryot ongoing sync.** This is a follow-up CronJob that reads the public diary RSS (`tmdb:movieId`) and posts to a Ryot Generic JSON sink. Ryot does not de-duplicate (upstream issue 1611), so the job keeps state.
10. **Minor:**
    - Jellyfin also mounts books, audiobooks and comics as `books` libraries, duplicating Kavita, Komga and ABS.
    - `docs/observability.md` still says qBittorrent is scaled to 0.
    - Music Assistant runs privileged and admits any signed-in user.

## Plan

- **Next, small:** confirm gap 3 after a real play, and fix `docs/observability.md`. Each is a one-file change.
- **Then:** gap 4 (e2e flows for the new apps, one e2e release). The Immich restore check (gap 5) is done.
- **Bigger:** request front ends for music and books, and the Letterboxd RSS job. Per-user music scrobbling (gap 6) is done.

## App notes

### Music scrobbling per user (2026-10)

Every person's plays go to that person's own history, and nothing is shared or admin-scoped.

- **Who.** `nixidy/apps/media/scrobbling.nix` takes the declared Keycloak users in the `family` or `admin` group (`keycloakUsers`, docs/invite.md), plus the `e2e` fixture user the music e2e flow scrobbles as. Inviting someone adds their scrobbling setup in the same merge, with no other edit and no secret to create.
- **Sinks.** Maloja has no accounts (one library per data directory), so a user's sink is a Maloja of their own. The owner keeps the original Maloja container; every other user is one more container of the same pod, with its own data directory (`/mljdata/users/<user>`, on the same PVC and backup), port (42011 and up, by name order), Service, API key and UI host `maloja-<user>.trdos.me` (that user and admins only, a new `users` option of `oauth2Proxy.upstreams`).
- **Routing.** multi-scrobbler is the router. Per user it has a Jellyfin source (`usersAllow` = the username, polling Jellyfin as the admin account), a ListenBrainz-endpoint source whose token selects it, and a Maloja client for the user's Maloja; both sources list only that client, so a user's plays can only reach their own Maloja. The config files are rendered into a Secret from generated tokens and keys.
- **Navidrome.** The ListenBrainz base URL is global and the token per user, so it points at multi-scrobbler's endpoint (`/1/`, which validates any configured token) and each user's token selects their source. The navidrome bootstrap (app-bootstrap 0.38+, `SCROBBLE_USERS`) acts as each user through the trusted header from a whitelisted pod IP: that creates the non-admin account the way their first sign-in would and links their token, with no per-user password.
- **Why not the alternatives** (not all verified): a self-hosted ListenBrainz is a heavy stack and, from memory, signs people in through MusicBrainz rather than Keycloak; Koito's docs mention one username and key per instance (unconfirmed); one Maloja with a key per user would only label scrobbles (`origin: client:<key>`), not separate them; Navidrome's and Jellyfin's own per-user play counts stay as they are but give no cross-app history.
- **Adding a user later** needs only the `keycloakUsers` entry. Removing the entry removes that user's Maloja container, Service and keys; the data directory stays on the PVC, and their Navidrome account stays like every per-app account.

### Acquisition choices (2026-10)

- **Books:** Readarr was archived on 2025-06-27, and its metadata server is gone. Bookshelf (`pennydreadful/bookshelf`, pushed 2026-09) is the maintained revival. Its `hardcover` images use rreading-glasses (`blampe/rreading-glasses`, a Hardcover-backed replacement metadata server), hosted at `api.bookinfo.pro`. Bookshelf handles one media type per instance, so there are two. Chaptarr, which had an empty stub here, was dropped.
- **Comics:** Kapowarr over Mylar3. Kapowarr had a release in 2026-09; Mylar3's last release was 2025-08. Kapowarr's GetComics direct downloads work without indexers. Prowlarr cannot sync to Kapowarr. Kapowarr needs a ComicVine API key (docs/manual-steps.md 14).
- **Manga:** Suwayomi, which is actively released. Kaizoku is archived and Mangarr is early. Suwayomi downloads CBZ files with ComicInfo into `media-manga`, and Komga's Ryot yank tracks reading. Extension stores are third-party, so none is configured by default.

### Sportarr

`nixidy/apps/media/arr/sportarr.nix`. It uses header auth behind oauth2-proxy (admin only), with the API key and auth mode seeded into `config.xml`. The bootstrap (`app-bootstrap sportarr`) adds:

- the root folder;
- qBittorrent;
- Prowlarr's sync;
- Wrexham (every competition) and the English Premier League, monitored from now on.

Files are deleted 30 days after an event aired (`retentionDays` in the module), because the sports volume is a 250Gi quota on a small Ceph pool.

### Tracearr

`nixidy/apps/media/tracearr.nix`. Native OIDC (Keycloak). The bootstrap:

- makes the owner with tristan's email;
- connects Jellyfin with an API key named `Tracearr`;
- enables sign-in for Jellyfin-synced users;
- sets up a daily backup.

It has no Prometheus metrics.

### Streamystats (in cluster only, no human access yet)

`nixidy/apps/media/streamystats.nix` is deployed with no route, portal entry or oauth2-proxy upstream. Its Services are ClusterIP and a network policy admits only its own pods, Maintainerr, the bootstrap Jobs, the e2e Job and the kubelet. It serves Maintainerr (the connection is added by the Maintainerr bootstrap) and ingests statistics from Jellyfin (the `app-bootstrap streamystats` Job adds the Jellyfin server with an API key named `Streamystats`).

Why no UI: Streamystats signs people in with a Jellyfin username and password, and keeps no other identity. Its session is a cookie signed with `SESSION_SECRET`, plus the person's Jellyfin token. Jellyfin SSO users have no password, so the only way in would be the shared Jellyfin admin account, which breaks the per-user rule.

Human access waits for a per-user path: a sidecar behind oauth2-proxy that gets that user's Jellyfin token without a password and mints Streamystats' session. Neither part is available cleanly today. When it exists, add the route and the oauth2-proxy upstream back.

### Subtitles for language practice

Subtitles in English, Portuguese, Spanish, French and German, for every movie and series.

- Bazarr (`nixidy/apps/media/arr/bazarr.nix`): the default profile `Language practice` holds `en`, `pt`, `pb`, `es`, `fr`, `de`. Bazarr keeps Portuguese (`pt`) and Brazilian Portuguese (`pb`) apart, so both are in the profile. The profile an earlier run named `English` is renamed in place, so the series and movies already on it follow.
- Lingarr: source `en`, targets `pt`, `es`, `fr`, `de` (no `pb`: a Brazilian subtitle comes from Bazarr only). It compares the target languages with the subtitle files beside each video and only translates the ones that are missing, so a subtitle Bazarr found is never overwritten. Two limits keep it modest: 5 files per nightly run (each file yields up to 4 translations) and, for new files, a 72 hour wait (`LINGARR_MIN_AGE_HOURS`) so Bazarr gets the first chance. Files already in the library are older than that, so for them Lingarr and Bazarr work in parallel; a machine translation that lands first counts as present for Bazarr.
- LibreTranslate loads only these five languages (`LT_LOAD_ONLY`, about 200 MB of models per pair on CPU, 4 GiB memory limit).
