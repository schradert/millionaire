//! Immich with the OIDC callback completed: the test user's Keycloak login creates its Immich
//! user, the user uploads a generated PNG and gets its thumbnail, deletes the asset, and the
//! service admin (the `e2e` admin app-bootstrap makes, whose API key is mounted) deletes the
//! user. Only another admin can: Immich refuses deleting your own account or the last admin.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{multipart, Method};
use serde_json::{json, Value};

use crate::{
    ctx::{chain, excerpt, json as get_json, need_secret, poll, random_hex, rfc3339, send, unix_now, At, Ctx, Fail, Scope, R},
    registry::oci::sha256_hex,
};

const APP: &str = "immich";

pub struct Admin {
    pub base: String,
    key: String,
}

impl Admin {
    /// Skips when the service admin's key is not mounted.
    pub fn connect() -> R<Self> {
        Ok(Admin { base: crate::svc::url("IMMICH_URL", "immich"), key: need_secret(APP, "e2e-immich", "apikey")? })
    }

    pub fn req(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, format!("{}/api{path}", self.base)).header("x-api-key", &self.key)
    }

    /// Users whose email carries a marker in scope: (id, email). A user deleted with `force` is
    /// removed by a queued job and may still be listed, marked `deletedAt`: that counts as gone.
    pub async fn tagged_users(&self, ctx: &Ctx, scope: &Scope) -> R<Vec<(String, String)>> {
        let v = get_json(self.req(ctx, Method::GET, "/admin/users"), APP, "list users").await?;
        Ok(v.as_array()
            .into_iter()
            .flatten()
            .filter(|u| u["deletedAt"].is_null())
            .filter_map(|u| Some((u["id"].as_str()?.to_string(), u["email"].as_str()?.to_string())))
            .filter(|(_, e)| scope.hit(e))
            .collect())
    }

    /// Delete a tagged user at once, with everything it owns.
    pub async fn delete_user(&self, ctx: &Ctx, id: &str, email: &str) -> R<()> {
        crate::svc::tagged(APP, email)?;
        send(self.req(ctx, Method::DELETE, &format!("/admin/users/{id}")).json(&json!({ "force": true })), APP, "delete user").await.map(|_| ())
    }
}

/// Family sweep and residue: tagged Immich users.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let admin = Admin::connect()?;
    let found = admin.tagged_users(ctx, scope).await?;
    if delete {
        for (id, email) in &found {
            admin.delete_user(ctx, id, email).await?;
        }
    }
    Ok(found.into_iter().map(|(_, e)| format!("immich user {e}")).collect())
}

// ---------- a generated image ----------

fn crc32(data: &[u8]) -> u32 {
    let mut c = 0xffff_ffffu32;
    for b in data {
        c ^= *b as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xedb8_8320 ^ (c >> 1) } else { c >> 1 };
        }
    }
    !c
}

fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for x in data {
        a = (a + *x as u32) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

fn chunk(kind: &[u8; 4], data: &[u8], out: &mut Vec<u8>) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let mut body = kind.to_vec();
    body.extend_from_slice(data);
    out.extend_from_slice(&body);
    out.extend_from_slice(&crc32(&body).to_be_bytes());
}

/// A `w` x `h` RGB PNG whose colours come from `seed` (stored deflate blocks: no compression library).
pub fn png(w: u32, h: u32, seed: &str) -> Vec<u8> {
    let s = sha256_hex(seed.as_bytes());
    let base: Vec<u8> = (0..3).map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap_or(0)).collect();
    let mut raw = Vec::new();
    for y in 0..h {
        raw.push(0);
        for x in 0..w {
            raw.extend_from_slice(&[base[0].wrapping_add((x * 4) as u8), base[1].wrapping_add((y * 4) as u8), base[2]]);
        }
    }
    let mut z = vec![0x78, 0x01];
    let blocks: Vec<&[u8]> = raw.chunks(65535).collect();
    for (i, b) in blocks.iter().enumerate() {
        z.push(u8::from(i + 1 == blocks.len()));
        z.extend_from_slice(&(b.len() as u16).to_le_bytes());
        z.extend_from_slice(&(!(b.len() as u16)).to_le_bytes());
        z.extend_from_slice(b);
    }
    z.extend_from_slice(&adler32(&raw).to_be_bytes());
    let mut out = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    chunk(b"IHDR", &ihdr, &mut out);
    chunk(b"IDAT", &z, &mut out);
    chunk(b"IEND", &[], &mut out);
    out
}

fn b64url(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..=c.len() {
            out.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

/// PKCE: `(verifier, S256 challenge)`.
pub fn pkce() -> R<(String, String)> {
    let verifier = format!("{}{}", random_hex()?, random_hex()?);
    let digest: Vec<u8> = (0..32).map(|i| u8::from_str_radix(&sha256_hex(verifier.as_bytes())[i * 2..i * 2 + 2], 16).unwrap_or(0)).collect();
    Ok((verifier, b64url(&digest)))
}

/// What the callback gives the signed-in test user.
pub struct Session {
    pub token: String,
    pub user_id: String,
    pub email: String,
}

/// The OAuth leg Immich owns: authorize (with our state and PKCE challenge), then, after the Keycloak
/// login, the callback that creates the user. `login` performs the Keycloak part for the URL
/// it is given and returns the URL Keycloak redirected back to.
pub async fn oauth_login<F, Fut>(ctx: &Ctx, base: &str, login: F) -> R<(Session, String)>
where
    F: FnOnce(String, String) -> Fut,
    Fut: std::future::Future<Output = R<String>>,
{
    let redirect = format!("{base}/auth/login");
    let (verifier, challenge) = pkce()?;
    let state = random_hex()?;
    let r: Value = get_json(
        ctx.http.post(format!("{base}/api/oauth/authorize")).json(&json!({ "redirectUri": redirect, "state": state, "codeChallenge": challenge })),
        APP,
        "oauth/authorize",
    )
    .await?;
    let url = r["url"].as_str().at(APP, "authorization url")?.to_string();
    let back = login(url.clone(), redirect).await?;
    let v = get_json(
        ctx.http.post(format!("{base}/api/oauth/callback")).json(&json!({ "url": back, "state": state, "codeVerifier": verifier })),
        APP,
        "oauth/callback",
    )
    .await?;
    let s = Session {
        token: v["accessToken"].as_str().at(APP, "accessToken")?.to_string(),
        user_id: v["userId"].as_str().at(APP, "userId")?.to_string(),
        email: v["userEmail"].as_str().unwrap_or_default().to_string(),
    };
    Ok((s, url))
}

/// Upload a generated PNG as the user, wait for its thumbnail, delete it (force) and check it is gone.
pub async fn asset_roundtrip(ctx: &Ctx, base: &str, s: &Session, marker: &str) -> R<String> {
    let bytes = png(64, 64, marker);
    let now = rfc3339(unix_now());
    let part = multipart::Part::bytes(bytes.clone()).file_name(format!("{marker}.png")).mime_str("image/png").at(APP, "multipart")?;
    let form = multipart::Form::new()
        .text("deviceAssetId", marker.to_string())
        .text("deviceId", "e2e")
        .text("fileCreatedAt", now.clone())
        .text("fileModifiedAt", now)
        .part("assetData", part);
    let r = get_json(ctx.http.post(format!("{base}/api/assets")).bearer_auth(&s.token).multipart(form), APP, "upload asset").await?;
    let id = r["id"].as_str().at(APP, "asset id")?.to_string();
    let thumb = poll(APP, "thumbnail", Duration::from_secs(120), Duration::from_secs(3), || async {
        let t = ctx
            .http
            .get(format!("{base}/api/assets/{id}/thumbnail?size=preview"))
            .bearer_auth(&s.token)
            .send_t()
            .await
            .map_err(|e| Fail::new(APP, "thumbnail", chain(&e)))?;
        if !t.status().is_success() {
            return Ok(None);
        }
        Ok(Some(t.bytes().await.at(APP, "thumbnail body")?.to_vec()))
    })
    .await?;
    if thumb.len() < 8 {
        return Err(Fail::new(APP, "thumbnail", format!("{} bytes", thumb.len())));
    }
    let info = get_json(ctx.http.get(format!("{base}/api/assets/{id}")).bearer_auth(&s.token), APP, "asset info").await?;
    if info["originalFileName"].as_str().is_some_and(|n| !n.contains(marker)) {
        return Err(Fail::new(APP, "asset info", excerpt(&info.to_string())));
    }
    send(ctx.http.delete(format!("{base}/api/assets")).bearer_auth(&s.token).json(&json!({ "ids": [id], "force": true })), APP, "delete asset").await?;
    // A forced delete is carried out by a queued job: the asset disappears within moments.
    poll(APP, "asset deleted", Duration::from_secs(60), Duration::from_secs(2), || async {
        let gone = ctx.http.get(format!("{base}/api/assets/{id}")).bearer_auth(&s.token).send_t().await.at(APP, "get deleted asset")?;
        Ok((!gone.status().is_success()).then_some(()))
    })
    .await?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksums() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
        assert_eq!(adler32(b"Wikipedia"), 0x11e6_0398);
    }

    #[test]
    fn png_has_the_right_structure() {
        let p = png(64, 64, "e2e-20261013-000000-abcd");
        assert_eq!(&p[..8], &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
        assert_eq!(&p[12..16], b"IHDR");
        assert_eq!(u32::from_be_bytes([p[16], p[17], p[18], p[19]]), 64);
        assert_eq!(&p[p.len() - 8..p.len() - 4], b"IEND");
        // chunk CRCs verify: IHDR is at 12..(12+4+13)
        assert_eq!(u32::from_be_bytes(p[29..33].try_into().unwrap()), crc32(&p[12..29]));
        assert_ne!(png(64, 64, "a"), png(64, 64, "b"));
    }

    #[test]
    fn pkce_challenge_is_the_s256_of_the_verifier() {
        let (v, c) = pkce().unwrap();
        assert_eq!(c.len(), 43);
        assert!(!c.contains(['+', '/', '=']));
        let digest: Vec<u8> = (0..32).map(|i| u8::from_str_radix(&sha256_hex(v.as_bytes())[i * 2..i * 2 + 2], 16).unwrap()).collect();
        assert_eq!(c, b64url(&digest));
        assert_eq!(b64url(b"\xfb\xff"), "-_8");
    }
}
