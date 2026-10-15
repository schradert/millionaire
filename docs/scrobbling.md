# Scrobbling streaming services into Trakt (and on to Letterboxd)

Trakt is the hub: Ryot imports from it (`nixidy/apps/media/ryot.nix`), and the Letterboxd robot below reads from it. This page covers how plays on Netflix, Max, Disney+, Prime Video and the like reach Trakt, what each route can and cannot see, and the Letterboxd sync.

Research date 2026-10-15. "Verified" means read in the project's own source or docs on that date; "unverified" means a claim from a secondary source or from reasoning, not checked against a device.

## What is installed

| Where | What | Why |
| --- | --- | --- |
| Brave (`modules/browser.nix`) | [Universal Trakt Scrobbler](https://github.com/trakt-tools/universal-trakt-scrobbler) (Chrome Web Store id `mbhadeogepkjdjeikcckdkjdjhhkhlid`) | The only maintained open-source route for Netflix, Max and Prime Video. MIT licensed; release 0.9.4 on 2026-10-09 and releases every few weeks since July (GitHub releases API). |
| Jellyfin (`traktPlugin` in `nixidy/apps/media/jellyfin.nix`) | Jellyfin Trakt plugin | Everything played from the homelab library, on any client including the Android TV app. |
| Obtainium catalog (`modules/android.nix`) | nothing | There is no maintained Android app that scrobbles streaming apps to Trakt (see below), so nothing was added. Pano Scrobbler, already in the catalog, is music only (Last.fm, ListenBrainz, Libre.fm, Pleroma; no Trakt). |

One-time, by hand: in Brave open the extension, log in to Trakt, then per service log in on the service's site and press **Sync** once (docs/manual-steps.md 13).

## How Universal Trakt Scrobbler sees plays

It does two things, both from the browser:

- **Scrobble**: while a title plays in a tab of that service, it reports start, pause and stop to Trakt. Only plays in the browser.
- **Sync**: it reads the service's own account-level viewing history and posts the entries to Trakt. This is what catches plays made on other devices, such as an Android TV.

I read the sync code (`src/services/*/…Api.ts` at master) to see whether the history is per account or per browser:

- **Netflix** calls the website's `viewingActivity` endpoint (`["aui","viewingActivity",page,50]`). That is the account's server-side viewing activity for the signed-in profile, so TV plays are included.
- **Prime Video** calls the account's watch-history page widget (`getWatchHistorySettingsPage`, widget `watch-history`). Server-side, TV plays included.
- **Max** calls Max's `markers` API on the account's markers host, which returns server-side playback positions with a creation time (my reading of the code; I did not run it). Plays from other devices should appear there, but that is the least certain of the three.
- **Disney+**: the service has `hasSync: false` and `hasAutoSync: false`. Scrobble only, so a play on the TV is never seen.

So the sync does capture plays from other devices for the three services that have one. It is per profile: the extension reads whichever profile is active in the browser session, so each family profile you want on Trakt needs its own sync run.

### Does the sync need a click?

The first one does. After that, no: the extension registers an hourly browser alarm (`check-auto-sync` in `src/common/AutoSync.ts`) and, for each service with auto sync on, syncs when the last sync is older than the configured number of days (default 7). It only fires when all of these hold: the service has auto sync (Netflix, Prime Video and Max do; Disney+ and Apple TV do not), you turned on **Auto sync** for it in the options, you have done one manual sync (it requires `lastSync > 0`), Brave is running, and the service session is still logged in. Set the interval to 1 day. Plays reach Trakt up to that long after you watch them, with the watch date taken from the service's history, so the Trakt timeline stays right.

If Brave was closed for days, the next hourly check after it opens catches up. If a service logs you out, the sync fails until you log in again.

### Per-service coverage

From the extension README table (verified 2026-10-15), plus the TV view from the code above.

| Service | Scrobbles in browser | History sync | Plays on a TV (Android TV) |
| --- | --- | --- | --- |
| Netflix | yes | yes, auto | yes, through sync, per profile |
| Max (HBO Max) | yes | yes, auto | probably, through sync (not run) |
| Prime Video | yes, English UI only | yes, auto | yes, through sync |
| Disney+ | yes | no | **no** with this extension |
| Apple TV | yes | no | **no** |
| Crunchyroll | no | yes, auto | yes, through sync |
| discovery+, MUBI, Crave, Viaplay, NRK, TV 2 Play, Kino.pub | yes | yes | yes, through sync |
| AMC+, Star+, SkyShowtime, Stremio (web), others | yes | no | no |
| Hulu, Peacock, Paramount+, YouTube | not on the list | not on the list | no |

The "yes through sync" cells follow from the account-level endpoints I read for Netflix, Prime Video and Max. For the other services marked yes I did not read the code; treat them as likely, not verified.

## Android TV

You watch on an Android TV, so the browser is not where most plays happen. What I could and could not establish:

- **Reading playback from another app is not available to ordinary apps.** Android's own docs say `MediaSessionManager.getActiveSessions` needs the `MEDIA_CONTENT_CONTROL` permission or an enabled notification listener, and that a session can opt out of being discoverable. I did not verify (on a device) whether Android TV lets a third-party app enable a notification listener, or what the Netflix, Max or Disney+ TV apps publish in their media session. I found no maintained GitHub project that does this for Trakt (GitHub repository searches for Trakt plus Android scrobbling returned only Kodi, Plex, Chromecast and desktop scrobblers). So the TV side stays unsolved on-device; the history sync above is the working path.
- **Trakt's own Streaming Scrobbler** (Trakt VIP, in the Trakt mobile apps, via the third-party Younify service) links to the streaming account and imports viewing history, with a first sync about ten minutes after linking and one about every 24 hours after ([AlternativeTo, Dec 2024](https://alternativeto.net/news/2024/12/trakt-tv-launches-streaming-scrobbler-to-sync-viewing-history-across-streaming-platforms/)). A review at launch listed Netflix, Hulu, Disney+, Max, Amazon Prime and Apple TV+ ([PCWorld](https://www.pcworld.com/article/2607062/trakt-helps-you-keep-track-of-your-streaming-shows.html)). Because it reads the account, it should also see TV plays and it is the only route found that covers Disney+, Hulu and Apple TV+. Unverified: current service list, whether it still works, and TV plays specifically. It costs a VIP plan and uses Trakt's own app (Play Store), so Obtainium cannot track it.
- **Kodi on Android TV** with the Trakt add-on ([script.trakt](https://github.com/razzeee/script.trakt), last pushed 2026-07-28) scrobbles what Kodi plays. It does not see Netflix or other apps.
- **Jellyfin on Android TV**: covered by the Jellyfin Trakt plugin, server side.
- **Stremio** on Android TV has its own Trakt link, but a January 2024 user report says it stopped scrobbling (an r/Stremio thread, "Stremio is not scrobbling to Trakt again"). Unverified now.

### Automating the history sync headlessly: not built

The question was whether a robot could run the sync so it does not depend on Brave being open, or use a service's history export. Findings:

- **Exports**: Netflix offers a CSV (Account, Profiles, a profile, Viewing activity, **Download all**) ([Netflix help](https://help.netflix.com/en/node/101917)). It is per profile and a manual click in a signed-in browser. I found no equivalent for Max, Disney+ or Prime Video (not exhaustively searched). A Netflix CSV also has titles only, so something would have to match them to Trakt; the extension already does that.
- **Headless run of the extension**: possible in principle (Chromium with the unpacked extension, signed in to each service). It would mean storing Netflix, Max and Prime logins in the cluster and passing their sign-in challenges (CAPTCHAs, one-time codes, "is this you" device checks) from a datacenter-looking client. Those logins are shared household accounts, so a flag or lock costs more than a Letterboxd account would. The Letterboxd robot deliberately does not try to get past bot checks, so it would not carry over.
- **Verdict**: not worth it now. The extension's own auto sync (set to 1 day) already runs without a click once Brave is open on the Mac. The gaps are Disney+ and the case where Brave stays closed; for those use Trakt's Streaming Scrobbler or accept the gap. Revisit if Brave is rarely open.

## Letterboxd sync robot

Letterboxd has no public write API. Its website accepts an import CSV, so `apps/letterboxd-sync` drives that page. It is off by default: until the flag is flipped (and the image is pinned) no CronJob, ExternalSecret or PVC renders.

### What it does each night

1. Reads the public Trakt profile's movie history through Trakt's API (`/users/<slug>/history/movies`, client id only, so the profile must be public) and the ratings (`/users/<slug>/ratings/movies`).
2. Keeps only plays newer than the cursor in `/state/state.json` (a 1 GiB PVC, VolSync-backed). The cursor is the newest `watched_at` handled, plus the history ids at that exact timestamp, so nothing is sent twice. Films already in the diary make later plays a rewatch.
3. Writes `/state/new-films.csv` in Letterboxd's import format (`tmdbID,imdbID,Title,Year,WatchedDate,Rating10,Rewatch`; `tmdbID` is an exact match). Plays with no TMDB id are skipped and reported. At most `MAX_FILMS` (100) per run, oldest first.
4. Waits a random 0 to 30 minutes, opens headless Chromium, signs in with Bitwarden `letterboxd/username` and `letterboxd/password`, opens `/import/`, picks the file, waits for the page's summary, then (only when `confirmImport` is true) clicks the confirm button.
5. Records the new cursor only after it sees the page's success text, and posts to the ntfy topic `media` with the titles added. Any failure also posts, with priority high.

First run only: with no state, it records the current history as the baseline and uploads nothing. Set `startAt` to backfill from a date.

### Safety design

- **Unrecognised outcome**: the batch is written to state as `pending` before the confirm click. If the click happens but no success text follows, the run fails and every later run refuses to upload, because the films may or may not be in the diary and a retry could duplicate them. Look at the diary, then set `pendingAction` to `ack` (they are there) or `discard` (they are not) in the nix file and run the job once (the binary also has `letterboxd-sync ack` / `discard` subcommands). The unit and flow tests cover both.
- **No retries** (`backoffLimit = 0`), one run a day, 0.8 to 2.5 s pauses between page actions, a random start time.
- **Stops at bot checks.** If a CAPTCHA or "checking your browser" page appears it saves a screenshot and the HTML under `/state/debug/` and stops. It does not try to solve or evade it.
- **Own account only.** It visits the sign-in page and the import page and nothing else. It reads nothing from Letterboxd.
- **Trial mode**: `confirmImport = false` (the default) uploads, reads the summary, notifies ntfy with the page's text, and stops without confirming. Use it for the first live runs.

### Risk, stated plainly

Letterboxd's terms may prohibit automated access, and an account that logs in from a headless browser on a datacenter-like address can be flagged or locked. I have not read the terms in force today or confirmed what Letterboxd does about it. The mitigations above lower the odds; they do not remove the risk. The account holds diary history you may care about, so use a recent Letterboxd data export (Settings, Data, Export) as the backup before turning it on. If you would rather not take the risk, leave it off and upload the CSV by hand at <https://letterboxd.com/import/> (`DRY_RUN=1` prints it).

### What is tested and what is not

Tested (falcon, `cargo test`, Chromium 155 from nixpkgs): Trakt paging, start-at filtering and error messages against a local stand-in; CSV generation (ordering, rewatches, ratings, quoting, missing TMDB ids); state save/load, `ack` and `discard`; the full browser flow against a local mock of the sign-in page, the import page and the confirm step (sign-in, upload, confirm, success detection, wrong password, unrecognised confirm and the resulting block, stop-before-confirm); ntfy delivery to a local stand-in.

Not tested: a real Letterboxd login, the real import page's markup (the selectors are generic: `input[name=username]`, `input[name=password]`, `input[type=file]`, a new button or link whose text contains "import" or "confirm", and success text matching "imported", "import complete" and the like) and Letterboxd's bot defences. Not tested against the live Trakt API either (no client id was available); the endpoint paths, `start_at`, `page`/`limit` and the `X-Pagination-Page-Count` header are from Trakt's API documentation as I know it, and Trakt's CORS headers confirm the pagination header names. Expect to adjust the selectors after the first trial run; the screenshots in `/state/debug/` are for that.

Settings (environment, see `nixidy/apps/media/letterboxd-sync.nix`): `TRAKT_USERNAME`, `TRAKT_CLIENT_ID_FILE`, `LETTERBOXD_USERNAME_FILE`, `LETTERBOXD_PASSWORD_FILE`, `STATE_DIR`, `NTFY_URL`, `NTFY_TOPIC`, `START_AT`, `DRY_RUN`, `STOP_BEFORE_CONFIRM`, `MAX_FILMS`, `JITTER_SECS`, `PENDING_ACTION`, `PACE_MS_MIN`/`PACE_MS_MAX`, `CONFIRM_WAIT_SECS`, `CHROMIUM_PATH`, `TRAKT_URL` and `LETTERBOXD_URL` (the last two exist for the tests).
