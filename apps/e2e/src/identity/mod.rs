//! Identity: Keycloak test users and the ways apps authenticate them.

mod flows;
pub mod kc;
mod oidc;
mod sweep;

use crate::{
    flow::{Family, FlowDef, Tier},
    step, sweep,
};

const NAME: &str = "identity";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "Keycloak test users; OIDC logins (Mealie, Jellyfin, Home Assistant, Sure, LibreChat, Immich, Bulwark), oauth2-proxy bearer, Forgejo token; user deletion",
        flows,
        cleanup: Some(sweep!(sweep::cleanup)),
        residue: Some(sweep!(sweep::residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    use Tier::Offline;
    let d = |name, about, act| FlowDef::new(NAME, name, Offline, about, act);
    vec![
        d("keycloak-user", "test users in their groups; tokens carry groups and the oauth2-proxy audience", step!(flows::user_tokens)).setup(step!(flows::ensure_users)).assert(step!(flows::wrong_password)),
        d("oidc-mealie", "native OIDC: both users sign in to Mealie through Keycloak's login pages", step!(flows::mealie)).setup(step!(flows::ensure_users)).cleanup(step!(flows::mealie_cleanup)),
        d("oidc-jellyfin", "native OIDC: both users sign in to Jellyfin through the SSO plugin; their users are deleted", step!(oidc::jellyfin)).setup(step!(flows::ensure_users)).cleanup(step!(oidc::jellyfin_cleanup)),
        d("oidc-home-assistant", "native OIDC: Keycloak login ends at Home Assistant's finish page with a one-time code", step!(oidc::home_assistant)).setup(step!(flows::ensure_users)),
        d("oidc-sure", "native OIDC, link-only: Keycloak authenticates the user, Sure refuses to create an account", step!(oidc::sure)).setup(step!(flows::ensure_users)),
        d("oidc-librechat", "native OIDC: Keycloak login creates the test user's LibreChat account, which the user then deletes", step!(oidc::librechat)).setup(step!(flows::ensure_users)),
        d("oidc-immich", "native OIDC: Immich's authorization URL, Keycloak login, redirect back with the code", step!(oidc::immich)).setup(step!(flows::ensure_users)),
        d("oidc-bulwark", "native OIDC: Bulwark's start route, Keycloak login, redirect back with the code", step!(oidc::bulwark)).setup(step!(flows::ensure_users)),
        d("proxy-bearer", "oauth2-proxy: no token redirects, admin bearer passes, family bearer gets 403", step!(flows::proxy_bearer)).setup(step!(flows::ensure_users)),
        d("forgejo-token", "Forgejo user mints a token; the direct /api route accepts it", step!(flows::forgejo_token)).cleanup(step!(crate::forgejo::cleanup_users)),
        d("user-lifecycle", "a user logs in, is deleted, and can no longer log in", step!(flows::lifecycle)).cleanup(step!(flows::lifecycle_cleanup)),
    ]
}
