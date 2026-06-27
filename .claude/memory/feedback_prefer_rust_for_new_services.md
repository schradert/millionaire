---
name: Prefer Rust for new homelab services / scripts
description: For new bespoke services and scripts in the millionaire homelab (CronJobs, sync utilities, watchers), the user prefers Rust over Python or shell.
type: feedback
originSessionId: 8f527e75-eaea-4cf5-a2cd-80223e63506e
---
When proposing new bespoke services for the homelab — CronJobs, API sync scripts, custom watchers, integrations between two APIs — write them in Rust rather than Python or shell.

**Why:** User explicit preference: "These days I want to do more Rust, so let's write it in that." Stated in the context of a Spotify ↔ Navidrome playlist-publishing sync that I'd initially scoped as ~150 lines of Python.

**How to apply:**
- For one-off scripts that fit in a CronJob / Kubernetes Job, default to a small Rust binary (a single `main.rs`), built into a container image.
- Reach for ecosystem crates: `rspotify`, `subsonic-types`, `reqwest`, `tokio`, `serde`. Match the Nix tooling already in the repo (any existing Rust services they may add).
- Shell scripts are still fine for genuinely-tiny glue (one-line cron jobs that wrap `curl | jq | curl`); the rule kicks in for anything that would otherwise grow into ~50+ lines of Python.
- For library-internal scripts (build scripts, ad-hoc one-shots) Python is still acceptable — the preference is specifically about new deployed services.
