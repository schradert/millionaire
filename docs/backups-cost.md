# Backblaze B2: usage and cost

Measured 2026-10-17 with the devshell (`b2 bucket get --show-size`, and `rclone size --json` per prefix with the VolSync key; keys are never printed).
Pricing read from <https://www.backblaze.com/cloud-storage/pricing> and <https://www.backblaze.com/cloud-storage/transaction-pricing> the same day.

## Pricing (2026-10-17)

| Item | Price |
|---|---|
| Storage | $6.95 per TB per month, billed per byte-hour; the first 10 GB are free. No minimum object size or storage duration. |
| Egress | Free up to 3x the monthly average stored; $0.01 per GB beyond that. |
| Transactions | Class A, B and C (uploads, downloads, lists, deletes) are free. Class D (event notifications only) is $0.004 per 10,000 after 2,500 a day, and unused here. |

The brief for this work assumed $6/TB; the page says $6.95, which the numbers below use. TB is taken as 10^12 bytes (an assumption: the pages read do not define the unit; B2 reports sizes in bytes).
Restoring everything (about 2.3 TB after the cleanups below) is inside the free egress allowance.

## What is in B2 now

One bucket, `trdos-me--volsync` (the only bucket the account key lists): 467,186 files and 5,261,954,205,650 bytes = **5.262 TB billed** (`totalSize`, every version of every file). It has no lifecycle rules.
`rclone size` on the current versions finds 188,416 objects and 3.217 TB. **The other 2.045 TB is deleted-but-kept versions**: B2 only hides what restic prunes, barman expires and rclone deletes, and bills it until a lifecycle rule removes it.
2.042 TB of that sits under `cnpg/` (listing `cnpg/` with versions shows 2,886 GiB against 984 GiB current).

Current monthly cost: 5.262 TB x $6.95 = **$36.57** (about $36.50 after the free 10 GB), $439 a year.

| Prefix | Current GiB | Notes |
|---|---|---|
| `volsync--media-storage--media-dvd` | 1173.3 | the DVD MKV library, still growing while discs are ripped |
| `cnpg/` (31 prefixes) | 984.0 | 2,885.7 GiB with deleted versions; per cluster below |
| `volsync--media-storage--media-movies` | 594.9 | |
| `systeamadeck-safety-net-2026-10-11` | 76.1 | one-off copy from the redeploy work |
| `volsync--media-storage--media-games` | 71.7 | |
| `falcon-safety-net-2026-10-11` | 43.3 | one-off copy |
| `volsync--prometheus--prometheus` | 18.7 | |
| `etcd` | 17.1 | 85 objects: 6-hourly snapshots; the retired `offsite-sirver-*` and `offsite-octopus-*` ones never expire (README 47) |
| `volsync--harbor--harbor-registry` | 12.7 | |
| `volsync--clickhouse--clickhouse` | 2.3 | |
| `volsync--immich--immich-machine-learning` | 1.1 | |
| the other 64 `volsync--*` repositories | 0.3 | one per backed-up PVC; each is kilobytes to megabytes |
| `bws-backup`, `headscale-backup`, `axolotl-safety-net-2026-10-12` | 0.3 | |

`cnpg/` per cluster, current versions (GiB): keycloak 160.1, gatus 152.3, radarr 61.2, contextforge 57.0, lidarr 56.2, sonarr 55.7, prowlarr 54.8, windmill 54.6, argo-workflows 39.5, harbor 38.3, mealie 29.2, forgejo 28.7, ryot 24.3, autobrr 23.1, and 17 more (149.1 together).
These databases are under 1 GiB each. The bytes are WAL: gatus holds 6.5 GiB of base backups and 145.9 GiB of WAL in 9,932 segments of about 15 MiB. A cluster with any writes archives a 16 MiB segment every few minutes, and barman stored them uncompressed.

Cost by source today (billed, including deleted versions): `cnpg/` 3.10 TB = $21.5 (59%), media-dvd 1.26 TB = $8.8 (24%), media-movies 0.64 TB = $4.4 (12%), the rest 0.26 TB = $1.8.

## What changed in this work

| Change | Effect |
|---|---|
| VolSync sources for loki, tempo, pyroscope, alertmanager, mimir-ingester, argo-events, harbor-jobservice, lingarr, frigate clips and exports, and every Coder workspace home | First syncs 2026-10-17: loki 1.7 GiB, mimir-ingester 1.3, tempo 0.4, pyroscope 0.04, one workspace home 0.3 (stored, after dedup); the rest are empty or kilobytes |
| `rgwOffsite` mirror of the Ceph RGW buckets (Mimir, Pyroscope, Argo Workflows) | First sync: mimir 17.8 GiB, pyroscope 3.3 GiB, argo-workflows 0 |
| CNPG `wal` and `data` compression `gzip` on every cluster | Measured on gatus after it took effect (12:42 PDT): five consecutive 16 MiB segments stored as 24 KB, 796 KB, 560 KB, 530 KB and 628 KB. Old objects stay as they are and age out with the 30-day retention |
| B2 lifecycle rule (Pulumi, PR #1138, **not applied**) | Deletes hidden versions 7 days after hiding. The deletion is permanent, so it is left for a manual `pulumi up --target 'urn:pulumi:prod::millionaire::b2:index/bucket:Bucket::volsync'` (preview: 1 resource to update, nothing else) |

Not backed up, by decision (`volsync.exempt` in `nixidy/system/storage/backup-coverage.nix`, which also feeds the `PVCWithoutBackup` alert): `frigate-media` (rolling recordings: it turns over weekly, so restic would upload nearly all of it each time and B2 would keep every replaced object), `media-downloads`, `media-sports`, `dvd-rip-work`, the model and Nix caches, `libretranslate`, `jellyfin-cache`, Trivy's database, Mimir's compactor and store-gateway volumes, and `tracearr-db` (its own daily dump on `tracearr-backup` is backed up).

## Projection

Assumptions: $6.95/TB/month; restic keeps one daily, weekly, monthly and yearly snapshot (`retain` default), so a repository holds about its live size plus the changes between those snapshots; no dedup across repositories; per-source sizes are the PVC's `kubelet_volume_stats_used_bytes` or the measured first sync.

| Source | Used now | B2 estimate | $/month |
|---|---|---|---|
| Mimir bucket (RGW mirror) | 17.8 GiB, +4 GiB/day before compaction | upper bound +130 GiB a month, no cap (retention is 0s by design) | 0.12 now, up to +0.9 each month |
| Pyroscope bucket (RGW mirror) | 3.3 GiB, +0.8 GiB/day | +25 GiB a month, no cap | 0.02 now, up to +0.2 each month |
| Loki (14-day retention) | 1.9 GiB | about 2x as chunks churn | 0.03 |
| Tempo (7-day retention) | 1.1 GiB | about 1-2 GiB | 0.01 |
| Mimir ingester | 5.7 GiB | 1.3 GiB at first sync, up to about 6 | 0.04 |
| Frigate clips + exports | empty (the app is off) | at most the two 20 GiB claims | up to 0.28 |
| Coder homes | 0.6 GiB per workspace | 0.3 GiB stored per workspace | 0.002 each |
| Pyroscope metastore, alertmanager, argo-events, harbor-jobservice, lingarr | under 0.2 GiB together | negligible | 0 |
| CNPG after gzip | 0.98 TB of WAL | about 0.04 TB WAL (about 25x, from the gatus sample) + about 0.04 TB base backups (assumed 2x); about 0.08 TB | 0.6 |

Totals:

| Scenario | TB billed | $/month |
|---|---|---|
| Today | 5.26 | 36.6 |
| Before this work, one month on (estimate) | about 6.2 | about 43 |
| Merged state, lifecycle rule not applied, 30 days on (old WAL aged out) | about 4.3 | about 30 |
| **Merged state plus the lifecycle rule applied** | **about 2.3** | **about 16** |

How these were derived. Today is the measured `totalSize`. "One month on" assumes the roughly 30 GiB a day of WAL that barman now expires (the 984 GiB of current WAL over its 30-day window) keeps becoming hidden versions, about +0.9 TB a month; that is an estimate from one rate, not a measurement over time. The third row is today's 2.16 TB of non-CNPG data, plus this work's 0.03 TB, plus 0.08 TB of CNPG, plus the 2.04 TB of hidden versions that stay until a lifecycle rule exists. The last row drops the hidden versions to about one week of churn (about 0.03 TB, assumed): 2.16 + 0.03 + 0.08 + 0.03 = 2.30 TB.
Every extra 100 GiB of ripped DVDs adds about $0.75 a month, and the DVD library is still growing.

## The three largest contributors, and what grows without bound

1. **`cnpg/`**: 3.10 TB billed, 59% of the bill, almost all WAL and its deleted versions. Fixed going forward by compression; the 2.04 TB already hidden needs the lifecycle rule.
2. **`media-dvd`**: 1.26 TB, $8.8, still growing while discs are ripped. It is data (days of encoding; the discs are the only other source), so B2 is the only copy off the cluster.
3. **`media-movies`**: 0.64 TB, $4.4.

Unbounded by design or by setup: **Mimir** (blocks kept forever, `compactor_blocks_retention_period = 0s`; the bucket was 17.8 GiB after four days, and the `MimirBucketGrowth` alert only reports the rate) and **Pyroscope** (`retention_period = 0s`). Their mirrors grow with them; `rclone sync` removes from B2 what compaction removes from Ceph, so the mirror is a copy of the compacted state, not of every block ever written. Loki (14 days) and Tempo (7 days) are bounded by retention. Frigate is bounded by its two 20 GiB claims, and the 1 TiB recordings volume is not in B2. The CNPG prefix is bounded by the 30-day retention once WAL is compressed. The `etcd/` prefix holds snapshots of retired servers that never expire.

Worth a decision: the two `*-safety-net-2026-10-11` prefixes (119 GiB, $0.9 a month) are manual copies from the redeploy work and can go once the reinstalled hosts are verified.

## Reproducing the numbers

```sh
# in the devshell; the VolSync key is bucket-scoped, so no `rclone lsd :s3:` with it
b2 bucket get --show-size trdos-me--volsync          # fileCount and totalSize, every version
export RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT=https://s3.us-west-004.backblazeb2.com RCLONE_S3_NO_CHECK_BUCKET=true
# RCLONE_S3_ACCESS_KEY_ID / RCLONE_S3_SECRET_ACCESS_KEY from `bws secret list` (backblaze/bucket/application_key_id, application_key), as in devenv.nix
rclone lsf --dirs-only :s3:trdos-me--volsync                      # the prefixes
rclone size --json :s3:trdos-me--volsync/<prefix>                 # current versions
rclone size --json --s3-versions :s3:trdos-me--volsync/<prefix>   # with deleted versions
```

A listing of a large prefix (`cnpg/gatus` has about 10,000 objects) takes a minute or two.
