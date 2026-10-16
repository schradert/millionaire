//! The media stack: Servarr chains, Jellyfin, books, music, SSO redirects and the VPN leak tests.

pub mod apps;
pub mod cleanup;
pub mod content;
mod flows_arr;
mod flows_books;
mod flows_dvdrip;
mod flows_integrations;
mod flows_media;
mod flows_vpn;

use crate::{
    ctx::{Ctx, Scope},
    flow::{Family, FlowDef, Tier},
    report::Flow,
    step, sweep,
};

const NAME: &str = "media";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "media",
        about: "Servarr chains, Jellyfin, books, music, SSO redirects, VPN leak tests",
        flows,
        cleanup: Some(sweep!(sweep_cleanup)),
        residue: Some(sweep!(sweep_residue)),
        finalize: Some(sweep!(sweep_sessions)),
    }
}

async fn sweep_cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    cleanup::cleanup(ctx, scope, dry).await
}

async fn sweep_residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    cleanup::residue(ctx, scope).await
}

async fn sweep_sessions(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    cleanup::sessions(ctx, scope, dry).await
}

/// VPN flows first (they gate the downloads), then the offline suite in its historic order.
fn flows() -> Vec<FlowDef> {
    use Tier::{Full, Offline};
    let d = |name, tier, about, act| FlowDef::new(NAME, name, tier, about, act);
    vec![
        d("vpn-ip", Full, "pod public IP is the VPN exit, never the home IP", step!(flows_vpn::ip)),
        d("vpn-dns", Full, "DNS only through gluetun's DoT server", step!(flows_vpn::dns)),
        d("vpn-killswitch", Full, "kill switch: nothing leaves eth0, nothing at all with the tunnel down", step!(flows_vpn::killswitch)),
        d("vpn-tracker-ip", Full, "trackers see the VPN IP, never the home IP", step!(flows_vpn::tracker)),
        d("sso", Offline, "OIDC discovery; every media app's login lands on Keycloak", step!(flows_media::sso)),
        d("kodi", Offline, "dvd WebDAV serves a test ISO (basic auth, range GETs)", step!(flows_media::kodi)),
        d("dvd-rip", Offline, "a synthetic DVD is encoded and published by dvdrip, then renamed and re-sorted", step!(flows_dvdrip::rip))
            .cleanup(step!(flows_dvdrip::cleanup)),
        d("books-kavita", Offline, "Kavita imports an EPUB into a test library; OPDS lists it", step!(flows_media::kavita)),
        d("books-komga", Offline, "Komga imports an EPUB into a test library; OPDS lists it", step!(flows_media::komga)),
        d("audiobookshelf", Offline, "Audiobookshelf imports an audiobook into a test library", step!(flows_media::audiobookshelf)),
        d("music", Offline, "Navidrome scans a track; a scrobble reaches Maloja", step!(flows_media::music)),
        d("recyclarr", Offline, "Recyclarr profiles exist; its CronJob succeeded recently", step!(flows_media::recyclarr)),
        d("movie-chain", Offline, "Radarr add and import, Jellyfin scan and playback", step!(flows_arr::movie_chain)),
        d("maintainerr", Offline, "Maintainerr evaluates a test rule group", step!(flows_media::maintainerr)),
        d("seerr", Offline, "a Seerr request reaches Radarr", step!(flows_arr::seerr)),
        // Before `lidarr`: needs The Slip in Lidarr without files, which `lidarr` then reuses.
        d(
            "ombi",
            Offline,
            "a header login makes a family account; an Ombi request reaches Radarr and an approved one monitors the album in Lidarr",
            step!(flows_arr::ombi),
        ),
        d("sonarr-chain", Offline, "Sonarr add and import, Jellyfin scan", step!(flows_arr::sonarr_chain)),
        d("lidarr", Offline, "Lidarr imports an album, Navidrome serves it", step!(flows_arr::lidarr)),
        d("prowlarr", Offline, "Prowlarr answers a search", step!(flows_arr::prowlarr)),
        d("bazarr", Offline, "Bazarr (skips until it has an API key and subtitle account)", step!(flows_media::bazarr)),
        d(
            "integrations-arr",
            Offline,
            "Sonarr, Radarr, Lidarr: root folder, qBittorrent client, health clean but for indexers",
            step!(flows_integrations::arr_apps),
        ),
        d(
            "integrations-prowlarr",
            Offline,
            "Prowlarr: apps synced, qBittorrent and FlareSolverr wired, indexers pushed to the apps",
            step!(flows_integrations::prowlarr_links),
        ),
        d(
            "integrations-bookshelf",
            Offline,
            "Bookshelf and Bookshelf Audio: root folder, qBittorrent client, metadata source, health clean, synced into Prowlarr",
            step!(flows_integrations::bookshelf),
        ),
        d(
            "integrations-kapowarr",
            Offline,
            "Kapowarr: API key, comics root folder, qBittorrent client, download folder, FlareSolverr",
            step!(flows_integrations::kapowarr),
        ),
        d("integrations-suwayomi", Offline, "Suwayomi: GraphQL aboutServer, CBZ downloads, FlareSolverr, sources", step!(flows_integrations::suwayomi)),
        d(
            "books-bookshelf",
            Offline,
            "Bookshelf and Bookshelf Audio add a public-domain author from the metadata source into a test root folder and list the works",
            step!(flows_books::author),
        ),
        d("integrations-qbittorrent", Offline, "qBittorrent saves to the shared downloads volume", step!(flows_integrations::qbittorrent_path)),
        d(
            "integrations-bazarr",
            Offline,
            "Bazarr: Sonarr and Radarr connected, the declared default language profile, providers",
            step!(flows_integrations::bazarr),
        ),
        d(
            "integrations-lingarr",
            Offline,
            "Lingarr: Sonarr and Radarr linked, scheduled translation on, LibreTranslate serves the languages",
            step!(flows_integrations::lingarr),
        ),
        d(
            "integrations-cleanuparr",
            Offline,
            "Cleanuparr: arr apps and qBittorrent connected, cleaning and the Seeker on, ntfy",
            step!(flows_integrations::cleanuparr),
        ),
        d("integrations-autobrr", Offline, "autobrr: download clients and a filter per arr app", step!(flows_integrations::autobrr)),
        d(
            "integrations-maintainerr",
            Offline,
            "Maintainerr: Jellyfin, Radarr, Sonarr, Seerr, Ombi, qBittorrent, ntfy connected",
            step!(flows_integrations::maintainerr),
        ),
        d("integrations-seerr", Offline, "Seerr: Jellyfin libraries, Radarr, Sonarr", step!(flows_integrations::seerr)),
        d("integrations-ombi", Offline, "Ombi: header login, Jellyfin libraries, Sonarr, Radarr, Lidarr, ntfy", step!(flows_integrations::ombi)),
    ]
}
