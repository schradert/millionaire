//! A minimal S3 client for Ceph's RADOS gateway: path-style requests signed with AWS Signature
//! Version 4 (`sha2` and `hmac`), enough to put, get, list and delete one object.

use crate::trace::SendTraced as _;
use hmac::{Hmac, Mac};
use reqwest::Method;
use sha2::{Digest, Sha256};

use crate::ctx::{enc, hex, unix_now, At, Ctx, R};

type HmacSha256 = Hmac<Sha256>;

pub struct S3 {
    pub endpoint: String,
    pub access_key: String,
    pub secret_key: String,
    pub region: String,
}

fn hmac(key: &[u8], data: &str) -> Vec<u8> {
    let mut m = HmacSha256::new_from_slice(key).expect("hmac accepts any key length");
    m.update(data.as_bytes());
    m.finalize().into_bytes().to_vec()
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

/// `YYYYMMDDTHHMMSSZ` for a unix time.
pub fn amz_date(unix: i64) -> String {
    crate::ctx::rfc3339(unix).replace(['-', ':'], "")
}

/// The SigV4 signature of a request. `headers` are the lowercase names and values that are
/// signed (including `host`, `x-amz-content-sha256` and `x-amz-date`); the request is
/// `(method, encoded path, canonical (sorted, encoded) query string)`.
pub fn signature(secret: &str, region: &str, (method, uri, query): (&str, &str, &str), headers: &[(&str, &str)], payload_hash: &str, date: &str) -> String {
    let mut h: Vec<(&str, &str)> = headers.to_vec();
    h.sort();
    let canonical_headers: String = h.iter().map(|(k, v)| format!("{k}:{}\n", v.trim())).collect();
    let signed = h.iter().map(|(k, _)| *k).collect::<Vec<_>>().join(";");
    let canonical = format!("{method}\n{uri}\n{query}\n{canonical_headers}\n{signed}\n{payload_hash}");
    let day = &date[..8];
    let scope = format!("{day}/{region}/s3/aws4_request");
    let to_sign = format!("AWS4-HMAC-SHA256\n{date}\n{scope}\n{}", sha256_hex(canonical.as_bytes()));
    let k = hmac(format!("AWS4{secret}").as_bytes(), day);
    let k = hmac(&k, region);
    let k = hmac(&k, "s3");
    let k = hmac(&k, "aws4_request");
    hex(&hmac(&k, &to_sign))
}

/// `/bucket/key` with each segment percent-encoded.
pub fn path(bucket: &str, key: &str) -> String {
    let mut p = format!("/{}", enc(bucket));
    if !key.is_empty() {
        p.push('/');
        p.push_str(&key.split('/').map(enc).collect::<Vec<_>>().join("/"));
    }
    p
}

impl S3 {
    /// One signed request; the status and body.
    pub async fn request(&self, ctx: &Ctx, method: Method, path: &str, query: &[(&str, &str)], body: Vec<u8>) -> R<(u16, String)> {
        let host = self.endpoint.split("://").nth(1).unwrap_or(&self.endpoint).trim_end_matches('/').to_string();
        let date = amz_date(unix_now());
        let hash = sha256_hex(&body);
        let mut q: Vec<(String, String)> = query.iter().map(|(k, v)| (enc(k), enc(v))).collect();
        q.sort();
        let query_string = q.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("&");
        let sig = signature(
            &self.secret_key,
            &self.region,
            (method.as_str(), path, &query_string),
            &[("host", &host), ("x-amz-content-sha256", &hash), ("x-amz-date", &date)],
            &hash,
            &date,
        );
        let auth = format!(
            "AWS4-HMAC-SHA256 Credential={}/{}/{}/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={sig}",
            self.access_key,
            &date[..8],
            self.region
        );
        let url = if query_string.is_empty() {
            format!("{}{path}", self.endpoint.trim_end_matches('/'))
        } else {
            format!("{}{path}?{query_string}", self.endpoint.trim_end_matches('/'))
        };
        let r = ctx
            .http
            .request(method, url)
            .header("x-amz-date", &date)
            .header("x-amz-content-sha256", &hash)
            .header("authorization", auth)
            .body(body)
            .send_t()
            .await
            .at("rados", "S3 request")?;
        let status = r.status().as_u16();
        Ok((status, r.text().await.at("rados", "S3 response")?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
    const EMPTY: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    /// AWS's documented example: GET Object with a Range header.
    #[test]
    fn matches_the_aws_get_object_example() {
        let sig = signature(
            SECRET,
            "us-east-1",
            ("GET", "/test.txt", ""),
            &[("host", "examplebucket.s3.amazonaws.com"), ("range", "bytes=0-9"), ("x-amz-content-sha256", EMPTY), ("x-amz-date", "20130524T000000Z")],
            EMPTY,
            "20130524T000000Z",
        );
        assert_eq!(sig, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41");
    }

    /// AWS's documented example: PUT Object (the key needs percent-encoding).
    #[test]
    fn matches_the_aws_put_object_example() {
        let body_hash = sha256_hex(b"Welcome to Amazon S3.");
        assert_eq!(body_hash, "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072");
        let sig = signature(
            SECRET,
            "us-east-1",
            ("PUT", "/test%24file.text", ""),
            &[
                ("date", "Fri, 24 May 2013 00:00:00 GMT"),
                ("host", "examplebucket.s3.amazonaws.com"),
                ("x-amz-content-sha256", &body_hash),
                ("x-amz-date", "20130524T000000Z"),
                ("x-amz-storage-class", "REDUCED_REDUNDANCY"),
            ],
            &body_hash,
            "20130524T000000Z",
        );
        assert_eq!(sig, "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd");
    }

    #[test]
    fn dates_and_paths() {
        assert_eq!(amz_date(0), "19700101T000000Z");
        assert_eq!(amz_date(20737 * 86400 + 3661), "20261011T010101Z");
        assert_eq!(path("b", "dir/a b.txt"), "/b/dir/a%20b.txt");
        assert_eq!(path("b", ""), "/b");
    }
}
