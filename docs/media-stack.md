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
| Jellyfin | OIDC (SSO plugin) | yes, roles from groups | jellyfin-bootstrap (wizard, libraries, SSO, plugins: TMDb Box Sets, Webhook) | PVC + VolSync | movies, tv, dvd (ro) | Radarr, Sonarr, Sportarr | Seerr, Ombi | → Ryot (Webhook sink, new) and → Maloja (multi-scrobbler); → Trakt behind `traktPlugin` | ServiceMonitor, dashboard | movie-chain, sonarr-chain, oidc-jellyfin |
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
| Navidrome | Header (`preferred_username`); Subsonic API direct | by name (auto-creation of non-bootstrapped users unverified) | yes | PVC + VolSync | music | Lidarr | none | → Maloja (ListenBrainz API), linked for tristan only | ServiceMonitor, dashboard | music, lidarr |
| Lidarr | Gate | no | `app-bootstrap arr` | CNPG + VolSync | music + downloads | Prowlarr, qBittorrent | none | n/a | exportarr; ntfy `media` (new) | lidarr |
| Music Assistant | Gate (any signed-in user) | no | none | PVC + VolSync | music (ro) | n/a | n/a | none | none | proxy smoke |
| Maloja | Gate (admin); scrobble API key-only | no (single-user) | init container (API keys) | PVC + VolSync | n/a | n/a | n/a | the scrobble sink; ListenBrainz forward is a TODO | none | music |
| multi-scrobbler | Gate (admin) | no | none | PVC + VolSync | n/a | n/a | n/a | Jellyfin → Maloja for tristan only | none | music (components only) |

Ryot has a music type, but no integration reads Navidrome, Maloja or ListenBrainz. Music history stays in Maloja.

### Books, audiobooks, comics, manga, podcasts

| App | Auth | Per-user | Bootstrap | Data | Library | Acquisition | Requests | Tracking | Metrics / dash | E2E |
|---|---|---|---|---|---|---|---|---|---|---|
| Audiobookshelf | OIDC | yes (auto-register, roles from `abs_groups`) | yes | config + metadata PVC, VolSync | audiobooks, podcasts | **Bookshelf Audio (new)**; ABS's own podcast feeds | none | → Ryot (yank + one-time import, new) | none upstream | audiobookshelf |
| Kavita | OIDC | yes (`provisionAccounts`) | yes | SQLite PVC + VolSync | books, comics, **manga (new)** | **Bookshelf (new)**, Kapowarr, Suwayomi | none | none (Ryot has no Kavita integration) | none upstream | books-kavita |
| Komga | OIDC | yes (account on first login, default non-admin roles; was link-only until #875) | yes | PVC + VolSync | comics, **manga (new)** | Kapowarr, Suwayomi | none | → Ryot (yank, new) | none (actuator needs creds) | books-komga |
| **Bookshelf / Bookshelf Audio (new)** | Gate | no (admin tool) | `app-bootstrap arr` | SQLite PVC + VolSync | books / audiobooks + downloads | Prowlarr (Readarr sync), qBittorrent | none | n/a | exportarr ServiceMonitor; ntfy `media` | none yet |
| **Kapowarr (new)** | Gate | no | `app-bootstrap kapowarr` | PVC + VolSync | comics + downloads | GetComics DDL, qBittorrent | none | n/a | none | none yet |
| **Suwayomi (new)** | Gate (`AUTH_MODE=none`) | no | env only | PVC + VolSync | manga (`media-manga`, new) | extension stores (none configured) | none | via Komga → Ryot | none | none yet |
| kosync (home) | own accounts | per-account | none | PVC + VolSync | n/a | n/a | n/a | KOReader progress | none | blocked (no account deletion) |

### Photos and live

| App | Auth | Per-user | Bootstrap | Data | Metrics | E2E |
|---|---|---|---|---|---|---|
| Immich | OIDC (email link) | yes | yes (API key, e2e admin) | CNPG without barman (in-app dump only, restore never verified) + library PVC VolSync | ServiceMonitor, dashboard | oidc-immich, upload |
| Owncast | own admin password | n/a | none | PVC + VolSync | none | planned |

### Tracking hub: Ryot

| | Before (2026-10-15 morning) | After |
|---|---|---|
| Integrations | none | Jellyfin sink (+ Jellyfin Webhook destination, PlaybackStart/Stop of movies and episodes for tristan); Audiobookshelf yank; Komga yank; Radarr and Sonarr push from the collection "Request" |
| Imports | none | Audiobookshelf (succeeded); Trakt by public profile behind the `trakt` flag |
| Out to Trakt | none | Jellyfin Trakt plugin behind `traktPlugin` (device link in Jellyfin, docs/manual-steps.md 13) |
| Letterboxd | none | not possible to write (no public API); see docs/manual-steps.md 13 |

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
4. **e2e coverage for the new acquirers.** Add flows for Bookshelf (root folder and Prowlarr app present), Kapowarr (API key and root folder) and Suwayomi (GraphQL `aboutServer`), on the media runner.
5. **Immich database backups.** An in-app dump runs daily, but no restore has ever been tested, and CNPG barman is off (the image lacks it). Fix: a barman-capable image, or add the dump to backup-verify.
6. **Music tracking is single-user.**
   - multi-scrobbler allows only tristan.
   - Maloja has a single user.
   - Navidrome's Maloja link exists only for tristan.
   - The ListenBrainz forward is a TODO that needs a user token.
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
- **Then:** gap 4 (e2e flows for the new apps, one e2e release) and the Immich restore check (backup-verify).
- **Bigger:** music multi-user scrobbling (Maloja is single-user by design, so move to ListenBrainz-compatible per-user sinks), request front ends for music and books, and the Letterboxd RSS job.

## App notes

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

### Streamystats (not deployed)

`nixidy/apps/media/streamystats.nix` is written and renders, but `nixidy/apps/default.nix` does not import it.

Streamystats signs people in with a Jellyfin username and password, and keeps no other identity. Its session is a cookie signed with `SESSION_SECRET`, plus the person's Jellyfin token. Jellyfin SSO users have no password, so the only way in left is the shared Jellyfin admin account, which breaks the per-user rule.

A per-user path needs a sidecar behind oauth2-proxy. The sidecar would get that user's Jellyfin token without a password and mint Streamystats' session; neither part is available cleanly today. Enable Streamystats once that exists. The bootstrap mode `app-bootstrap streamystats` is already in place.
