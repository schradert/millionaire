//! Just enough of the OCI image format and the registry HTTP API to push a generated image and
//! pull it back: SHA-256, a one-file tar layer, the config and manifest documents, and blob and
//! manifest transfers with a bearer token (Distribution API v2, as `crane` and `skopeo` use it).

use crate::trace::SendTraced as _;
use reqwest::Method;
use serde_json::{json, Value};

use crate::ctx::{excerpt, At, Ctx, Fail, R};

/// SHA-256 as lowercase hex.
pub fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for (i, word) in chunk.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7].wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [t1.wrapping_add(t2), v[0], v[1], v[2], v[3].wrapping_add(t1), v[4], v[5], v[6]];
        }
        for (x, y) in h.iter_mut().zip(v) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

pub fn digest(data: &[u8]) -> String {
    format!("sha256:{}", sha256_hex(data))
}

/// An uncompressed tar holding one regular file (`name`, `content`), as an image layer.
pub fn tar_one_file(name: &str, content: &[u8]) -> Vec<u8> {
    let mut h = [0u8; 512];
    h[..name.len().min(100)].copy_from_slice(&name.as_bytes()[..name.len().min(100)]);
    h[100..107].copy_from_slice(b"0000644");
    h[108..115].copy_from_slice(b"0000000");
    h[116..123].copy_from_slice(b"0000000");
    h[124..135].copy_from_slice(format!("{:011o}", content.len()).as_bytes());
    h[136..147].copy_from_slice(b"00000000000");
    h[156] = b'0';
    h[257..262].copy_from_slice(b"ustar");
    h[263..265].copy_from_slice(b"00");
    h[148..156].copy_from_slice(b"        ");
    let sum: u32 = h.iter().map(|b| *b as u32).sum();
    h[148..155].copy_from_slice(format!("{sum:06o}\0").as_bytes());
    h[155] = b' ';
    let mut out = h.to_vec();
    out.extend_from_slice(content);
    out.resize(512 + content.len().div_ceil(512) * 512 + 1024, 0);
    out
}

/// The content of the first regular file in a tar (`tar_one_file`'s inverse).
pub fn tar_first_file(tar: &[u8]) -> Option<(String, Vec<u8>)> {
    let h = tar.get(..512)?;
    let name = String::from_utf8_lossy(&h[..100]).trim_end_matches('\0').to_string();
    let size = usize::from_str_radix(String::from_utf8_lossy(&h[124..135]).trim_matches(['\0', ' ']), 8).ok()?;
    Some((name, tar.get(512..512 + size)?.to_vec()))
}

/// A generated image: its blobs `(digest, bytes)` and the manifest bytes.
pub struct Image {
    pub layer: (String, Vec<u8>),
    pub config: (String, Vec<u8>),
    pub manifest: Vec<u8>,
}

pub const MANIFEST_TYPE: &str = "application/vnd.oci.image.manifest.v1+json";

/// One layer holding `/e2e.txt` = `text`, a minimal config, and the manifest tying them together.
pub fn image(text: &str) -> Image {
    let layer_bytes = tar_one_file("e2e.txt", text.as_bytes());
    let layer = (digest(&layer_bytes), layer_bytes);
    let config_bytes =
        json!({ "architecture": "amd64", "os": "linux", "config": { "Cmd": ["/e2e.txt"] }, "rootfs": { "type": "layers", "diff_ids": [layer.0] } })
            .to_string()
            .into_bytes();
    let config = (digest(&config_bytes), config_bytes);
    let manifest = json!({
        "schemaVersion": 2,
        "mediaType": MANIFEST_TYPE,
        "config": { "mediaType": "application/vnd.oci.image.config.v1+json", "digest": config.0, "size": config.1.len() },
        "layers": [{ "mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": layer.0, "size": layer.1.len() }],
    })
    .to_string()
    .into_bytes();
    Image { layer, config, manifest }
}

/// A registry endpoint with a bearer token for one repository.
pub struct Registry {
    pub base: String,
    pub token: String,
}

impl Registry {
    /// Token from Harbor's token service with `user`/`pass` (a robot) for `repo` push and pull.
    pub async fn login(ctx: &Ctx, app: &str, base: &str, user: &str, pass: &str, repo: &str) -> R<Self> {
        let r = ctx
            .http
            .get(format!("{base}/service/token"))
            .query(&[("service", "harbor-registry"), ("scope", &format!("repository:{repo}:push,pull"))])
            .basic_auth(user, Some(pass))
            .send_t()
            .await
            .at(app, "registry token")?;
        let status = r.status();
        let v: Value = r.json().await.unwrap_or(Value::Null);
        if !status.is_success() {
            return Err(Fail::new(app, "registry token", format!("HTTP {status}: {}", excerpt(&v.to_string()))));
        }
        let token = v["token"].as_str().or(v["access_token"].as_str()).at(app, "token in response")?.to_string();
        Ok(Registry { base: base.trim_end_matches('/').to_string(), token })
    }

    fn req(&self, ctx: &Ctx, m: Method, url: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, url).bearer_auth(&self.token)
    }

    /// Push one blob (monolithic upload).
    pub async fn push_blob(&self, ctx: &Ctx, app: &str, repo: &str, (dig, bytes): &(String, Vec<u8>)) -> R<()> {
        let r = self.req(ctx, Method::POST, &format!("{}/v2/{repo}/blobs/uploads/", self.base)).send_t().await.at(app, "start upload")?;
        if r.status().as_u16() != 202 {
            return Err(Fail::new(app, "start upload", format!("HTTP {}: {}", r.status(), excerpt(&r.text().await.unwrap_or_default()))));
        }
        let loc = r.headers().get("location").and_then(|v| v.to_str().ok()).at(app, "upload location")?.to_string();
        // The registry may answer with its external URL: keep path and query, use our base.
        let path = loc.find("/v2/").map(|i| &loc[i..]).unwrap_or(&loc);
        let url = format!("{}{path}{}digest={dig}", self.base, if path.contains('?') { "&" } else { "?" });
        let r = self.req(ctx, Method::PUT, &url).header("content-type", "application/octet-stream").body(bytes.clone()).send_t().await.at(app, "put blob")?;
        if r.status().as_u16() != 201 {
            return Err(Fail::new(app, "put blob", format!("HTTP {}: {}", r.status(), excerpt(&r.text().await.unwrap_or_default()))));
        }
        Ok(())
    }

    pub async fn push_manifest(&self, ctx: &Ctx, app: &str, repo: &str, tag: &str, manifest: &[u8]) -> R<()> {
        let r = self
            .req(ctx, Method::PUT, &format!("{}/v2/{repo}/manifests/{tag}", self.base))
            .header("content-type", MANIFEST_TYPE)
            .body(manifest.to_vec())
            .send_t()
            .await
            .at(app, "put manifest")?;
        if r.status().as_u16() != 201 {
            return Err(Fail::new(app, "put manifest", format!("HTTP {}: {}", r.status(), excerpt(&r.text().await.unwrap_or_default()))));
        }
        Ok(())
    }

    /// (manifest bytes, the registry's `Docker-Content-Digest`).
    pub async fn pull_manifest(&self, ctx: &Ctx, app: &str, repo: &str, tag: &str) -> R<(Vec<u8>, String)> {
        let r = self
            .req(ctx, Method::GET, &format!("{}/v2/{repo}/manifests/{tag}", self.base))
            .header("accept", MANIFEST_TYPE)
            .send_t()
            .await
            .at(app, "get manifest")?;
        if !r.status().is_success() {
            return Err(Fail::new(app, "get manifest", format!("HTTP {}", r.status())));
        }
        let d = r.headers().get("docker-content-digest").and_then(|v| v.to_str().ok()).unwrap_or_default().to_string();
        Ok((r.bytes().await.at(app, "manifest body")?.to_vec(), d))
    }

    pub async fn pull_blob(&self, ctx: &Ctx, app: &str, repo: &str, dig: &str) -> R<Vec<u8>> {
        let r = self.req(ctx, Method::GET, &format!("{}/v2/{repo}/blobs/{dig}", self.base)).send_t().await.at(app, "get blob")?;
        if !r.status().is_success() {
            return Err(Fail::new(app, "get blob", format!("HTTP {}", r.status())));
        }
        Ok(r.bytes().await.at(app, "blob body")?.to_vec())
    }

    /// The HTTP status of a manifest GET (404 once the artifact is deleted).
    pub async fn manifest_status(&self, ctx: &Ctx, app: &str, repo: &str, tag: &str) -> R<u16> {
        Ok(self
            .req(ctx, Method::GET, &format!("{}/v2/{repo}/manifests/{tag}", self.base))
            .header("accept", MANIFEST_TYPE)
            .send_t()
            .await
            .at(app, "get manifest")?
            .status()
            .as_u16())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_vectors() {
        assert_eq!(sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(sha256_hex(&[b'a'; 1000]), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3");
    }

    #[test]
    fn tar_roundtrip_and_header_checksum() {
        let t = tar_one_file("e2e.txt", b"hello");
        assert_eq!(t.len() % 512, 0);
        assert_eq!(tar_first_file(&t), Some(("e2e.txt".into(), b"hello".to_vec())));
        // the checksum field is the sum of the header bytes with the field read as spaces
        let sum: u32 = t[..512].iter().enumerate().map(|(i, b)| if (148..156).contains(&i) { 32 } else { *b as u32 }).sum();
        assert_eq!(u32::from_str_radix(String::from_utf8_lossy(&t[148..154]).trim(), 8).unwrap(), sum);
    }

    #[test]
    fn manifest_names_the_blobs() {
        let img = image("e2e-20261013-000000-abcd");
        let m: Value = serde_json::from_slice(&img.manifest).unwrap();
        assert_eq!(m["layers"][0]["digest"].as_str(), Some(img.layer.0.as_str()));
        assert_eq!(m["config"]["digest"].as_str(), Some(img.config.0.as_str()));
        assert_eq!(m["config"]["size"].as_u64(), Some(img.config.1.len() as u64));
        let cfg: Value = serde_json::from_slice(&img.config.1).unwrap();
        assert_eq!(cfg["rootfs"]["diff_ids"][0].as_str(), Some(img.layer.0.as_str()));
    }
}
