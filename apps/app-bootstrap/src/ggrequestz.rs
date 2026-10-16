//! GG Requestz: tristan's admin row, so the first login is not whoever arrives first.
//!
//! GG Requestz makes the first user to sign in an admin, and links an OIDC login to an existing
//! row by email (keeping its roles). The app has no admin API, so the bootstrap inserts the row
//! in its database: waits for the app's own migrations (`ggr_users`), then adds tristan with the
//! profile email as admin when no row has that email, and sets `is_admin` if the row exists
//! without it. Tristan's Keycloak login then links to this row; the `admin` group keeps it admin.

use std::time::Duration;

use crate::common::{retry, secret, var, Result};

pub async fn run() -> Result<()> {
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let name = var("ADMIN_NAME", "Admin");
    let user = var("ADMIN_USER", "tristan");
    let mut cfg = tokio_postgres::Config::new();
    cfg.host(var("GGREQUESTZ_DB_HOST", "ggrequestz-rw.media.svc.cluster.local"))
        .user(var("GGREQUESTZ_DB_USER", "ggrequestz"))
        .password(secret("GGREQUESTZ_DB_PASSWORD")?)
        .dbname(var("GGREQUESTZ_DB_NAME", "ggrequestz"))
        .connect_timeout(Duration::from_secs(30));

    let db = retry("waiting for the ggrequestz schema", 120, || async {
        let (db, conn) = cfg.connect(tokio_postgres::NoTls).await?;
        tokio::spawn(async move {
            if let Err(e) = conn.await {
                eprintln!("ggrequestz database connection: {e}");
            }
        });
        let ready = db.query_one("SELECT to_regclass('ggr_users') IS NOT NULL", &[]).await?.get::<_, bool>(0);
        if !ready {
            return Err("ggr_users does not exist yet".into());
        }
        Ok(db)
    })
    .await?;

    let created = db
        .execute(
            "INSERT INTO ggr_users (email, name, preferred_username, is_admin, is_active)
             SELECT $1, $2, $3, TRUE, TRUE WHERE NOT EXISTS (SELECT 1 FROM ggr_users WHERE lower(email) = lower($1))",
            &[&email, &name, &user],
        )
        .await?;
    if created > 0 {
        println!("created admin {email}");
        return Ok(());
    }
    let promoted = db.execute("UPDATE ggr_users SET is_admin = TRUE, updated_at = NOW() WHERE lower(email) = lower($1) AND NOT is_admin", &[&email]).await?;
    println!("{email} exists{}", if promoted > 0 { ", made admin" } else { " as admin" });
    Ok(())
}
