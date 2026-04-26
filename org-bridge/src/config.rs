use clap::Parser;

#[derive(Parser, Debug, Clone)]
#[command(name = "org-bridge", about = "Bridges org-mode files to CalDAV")]
pub struct Config {
    /// Path to the org files directory
    #[arg(long, env = "ORG_DIR")]
    pub org_dir: String,

    /// Syncthing REST API base URL
    #[arg(long, env = "SYNCTHING_URL")]
    pub syncthing_url: String,

    /// Syncthing API key
    #[arg(long, env = "SYNCTHING_API_KEY")]
    pub syncthing_api_key: String,

    /// CalDAV base URL for the calendar collection
    #[arg(long, env = "CALDAV_URL")]
    pub caldav_url: String,

    /// CalDAV username
    #[arg(long, env = "CALDAV_USERNAME")]
    pub caldav_username: String,

    /// CalDAV password
    #[arg(long, env = "CALDAV_PASSWORD")]
    pub caldav_password: String,

    /// Path to the SQLite state database
    #[arg(long, env = "STATE_DB_PATH", default_value = "/var/lib/org-bridge/state.db")]
    pub state_db_path: String,
}
