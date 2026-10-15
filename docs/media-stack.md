# Media stack notes

## Sportarr

`nixidy/apps/media/arr/sportarr.nix`. Header auth behind oauth2-proxy (admin only), API key and auth mode seeded into
`config.xml`. The bootstrap (`app-bootstrap sportarr`) adds the root folder, qBittorrent, Prowlarr's sync, Wrexham (every
competition) and the English Premier League, monitored from now on. Files are deleted 30 days after an event aired
(`retentionDays` in the module), because the sports volume is a 250Gi quota on a small Ceph pool.

## Tracearr

`nixidy/apps/media/tracearr.nix`. Native OIDC (Keycloak). The bootstrap makes the owner with tristan's email, connects
Jellyfin with an API key named `Tracearr`, enables sign-in for Jellyfin-synced users and a daily backup. No Prometheus metrics.

## Streamystats (not deployed)

`nixidy/apps/media/streamystats.nix` is written and renders, but is not imported in `nixidy/apps/default.nix`.
Streamystats signs people in with a Jellyfin username and password and keeps no other identity: the session is a cookie
signed with `SESSION_SECRET` plus the person's Jellyfin token. Jellyfin SSO users have no password, and the only way in
left is the shared Jellyfin admin account, which breaks the per-user rule. A per-user path needs a sidecar behind
oauth2-proxy that obtains that user's Jellyfin token without a password and mints Streamystats' session; neither is
available cleanly today. Enable it once that exists (the bootstrap mode `app-bootstrap streamystats` is already in place).
