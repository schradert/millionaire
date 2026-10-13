//! Actual Budget's sync server as the clients use it. The server password (the bootstrap's
//! generated break-glass one, never the owner's OpenID login) signs in; a tagged budget file is
//! uploaded, a tagged transaction goes through the sync protocol (protobuf CRDT messages) and a
//! second client's sync pulls it, then the file is deleted and the server no longer lists it.
//! The file's bytes are a stand-in: the server stores budget blobs without opening them.

use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{excerpt, json as get_json, need_secret, send, At, Ctx, Fail, Scope, R},
    report::Flow,
    svc::{tagged, url, uuid4},
};

const APP: &str = "actual";
const ZERO: &str = "1970-01-01T00:00:00.000Z-0000-0000000000000000";

// ---------- protobuf (just the few messages the sync endpoint uses) ----------

fn varint(mut n: u64, out: &mut Vec<u8>) {
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

fn field(num: u32, payload: &[u8], out: &mut Vec<u8>) {
    varint(((num as u64) << 3) | 2, out);
    varint(payload.len() as u64, out);
    out.extend_from_slice(payload);
}

/// `Message { dataset = 1; row = 2; column = 3; value = 4 }`
pub fn message(dataset: &str, row: &str, column: &str, value: &str) -> Vec<u8> {
    let mut m = Vec::new();
    for (i, s) in [dataset, row, column, value].iter().enumerate() {
        field(i as u32 + 1, s.as_bytes(), &mut m);
    }
    m
}

/// `SyncRequest { messages = 1 (MessageEnvelope { timestamp = 1, content = 3 }); fileId = 2; groupId = 3; since = 6 }`
pub fn sync_request(messages: &[(String, Vec<u8>)], file_id: &str, group_id: &str, since: &str) -> Vec<u8> {
    let mut out = Vec::new();
    for (ts, content) in messages {
        let mut env = Vec::new();
        field(1, ts.as_bytes(), &mut env);
        field(3, content, &mut env);
        field(1, &env, &mut out);
    }
    field(2, file_id.as_bytes(), &mut out);
    field(3, group_id.as_bytes(), &mut out);
    field(6, since.as_bytes(), &mut out);
    out
}

fn read_varint(b: &[u8], i: &mut usize) -> Option<u64> {
    let (mut n, mut shift) = (0u64, 0);
    loop {
        let x = *b.get(*i)?;
        *i += 1;
        n |= ((x & 0x7f) as u64) << shift;
        if x & 0x80 == 0 {
            return Some(n);
        }
        shift += 7;
    }
}

/// Length-delimited fields of one message: (field number, bytes). Other wire types are skipped.
pub fn fields(b: &[u8]) -> Vec<(u32, Vec<u8>)> {
    let (mut i, mut out) = (0, Vec::new());
    while i < b.len() {
        let Some(key) = read_varint(b, &mut i) else { break };
        match key & 7 {
            0 => {
                if read_varint(b, &mut i).is_none() {
                    break;
                }
            }
            2 => {
                let Some(len) = read_varint(b, &mut i) else { break };
                let end = i + len as usize;
                if end > b.len() {
                    break;
                }
                out.push(((key >> 3) as u32, b[i..end].to_vec()));
                i = end;
            }
            1 => i += 8,
            5 => i += 4,
            _ => break,
        }
    }
    out
}

/// The `(timestamp, dataset, row, column, value)` of every message in a `SyncResponse`.
pub fn response_messages(resp: &[u8]) -> Vec<(String, String, String, String, String)> {
    let text = |b: &[u8]| String::from_utf8_lossy(b).to_string();
    fields(resp)
        .into_iter()
        .filter(|(n, _)| *n == 1)
        .map(|(_, env)| {
            let f = fields(&env);
            let get = |n| f.iter().find(|(k, _)| *k == n).map(|(_, v)| v.clone()).unwrap_or_default();
            let m = fields(&get(3));
            let mget = |n| m.iter().find(|(k, _)| *k == n).map(|(_, v)| text(v)).unwrap_or_default();
            (text(&get(1)), mget(1), mget(2), mget(3), mget(4))
        })
        .collect()
}

/// A hybrid-logical-clock timestamp for `unix_ms` and a counter, from a fixed test node.
pub fn timestamp(unix_ms: i64, counter: u32) -> String {
    format!("{}.{:03}Z-{counter:04X}-{}", crate::ctx::rfc3339(unix_ms / 1000).trim_end_matches('Z'), unix_ms.rem_euclid(1000), "e2e0e2e0e2e0e2e0")
}

// ---------- the server ----------

struct Server {
    base: String,
    token: String,
}

impl Server {
    async fn login(ctx: &Ctx) -> R<Self> {
        let pw = need_secret(APP, "e2e-actual", "password")?;
        let base = url("ACTUAL_URL", "actual");
        let v = get_json(ctx.http.post(format!("{base}/account/login")).json(&json!({ "loginMethod": "password", "password": pw })), APP, "login").await?;
        let token = v["data"]["token"].as_str().at(APP, "login token")?.to_string();
        Ok(Server { base, token })
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, format!("{}{path}", self.base)).header("x-actual-token", &self.token)
    }

    async fn files(&self, ctx: &Ctx) -> R<Vec<Value>> {
        let v = get_json(self.req(ctx, Method::GET, "/sync/list-user-files"), APP, "list files").await?;
        Ok(v["data"].as_array().cloned().unwrap_or_default())
    }

    async fn sync(&self, ctx: &Ctx, body: Vec<u8>) -> R<Vec<u8>> {
        let r = send(self.req(ctx, Method::POST, "/sync/sync").header("content-type", "application/actual-sync").body(body), APP, "sync").await?;
        Ok(r.bytes().await.at(APP, "sync response")?.to_vec())
    }

    async fn delete_file(&self, ctx: &Ctx, id: &str) -> R<()> {
        send(self.req(ctx, Method::POST, "/sync/delete-user-file").json(&json!({ "fileId": id })), APP, "delete file").await.map(|_| ())
    }
}

pub async fn budget(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let srv = Server::login(ctx).await?;
    let m = tagged(APP, &ctx.marker)?;
    f.ok(APP, "server password signs in", "session token");

    let (file_id, blob) = (uuid4()?, format!("e2e budget blob {m}"));
    let r = send(
        srv.req(ctx, Method::POST, "/sync/upload-user-file")
            .header("x-actual-name", m)
            .header("x-actual-file-id", &file_id)
            .header("x-actual-format", "2")
            .header("content-type", "application/encrypted-file")
            .body(blob.clone()),
        APP,
        "upload file",
    )
    .await?;
    let group: String = r.json::<Value>().await.at(APP, "upload response")?["groupId"].as_str().at(APP, "groupId")?.to_string();
    f.ok(APP, "tagged budget file uploaded", format!("{m} ({file_id})"));

    let listed = srv.files(ctx).await?;
    if !listed.iter().any(|x| x["fileId"].as_str() == Some(&file_id) && x["name"].as_str() == Some(m)) {
        return Err(Fail::new(APP, "list files", format!("the file is not listed: {}", excerpt(&json!(listed).to_string()))));
    }
    let got = send(srv.req(ctx, Method::GET, "/sync/download-user-file").header("x-actual-file-id", &file_id), APP, "download file").await?.text().await.at(APP, "download")?;
    if got != blob {
        return Err(Fail::new(APP, "download file", format!("got {got:?}")));
    }
    f.ok(APP, "file listed and downloaded", "bytes equal");

    // One CRDT message: a transaction's notes. A second sync from time zero returns it.
    let (row, notes) = (uuid4()?, format!("S:{m} coffee"));
    let ts = timestamp(crate::ctx::unix_now() * 1000, 0);
    let msg = (ts.clone(), message("transactions", &row, "notes", &notes));
    srv.sync(ctx, sync_request(&[msg], &file_id, &group, ZERO)).await?;
    let back = response_messages(&srv.sync(ctx, sync_request(&[], &file_id, &group, ZERO)).await?);
    if !back.iter().any(|(t, d, r, c, v)| *t == ts && d == "transactions" && *r == row && c == "notes" && *v == notes) {
        return Err(Fail::new(APP, "sync", format!("the second client does not see the transaction: {back:?}")));
    }
    f.ok(APP, "transaction synced to a second client", format!("transactions/{row}/notes"));

    srv.delete_file(ctx, &file_id).await?;
    if srv.files(ctx).await?.iter().any(|x| x["fileId"].as_str() == Some(&file_id)) {
        return Err(Fail::new(APP, "file deleted", "still listed after delete"));
    }
    f.ok(APP, "file deleted", "no longer listed");
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !found.is_empty() {
        f.ok(APP, "leftovers deleted", found.join(", "));
    }
    Ok(())
}

/// Family sweep and residue: tagged budget files.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let srv = Server::login(ctx).await?;
    let found: Vec<(String, String)> = srv.files(ctx).await?.iter().filter_map(|x| Some((x["fileId"].as_str()?.to_string(), x["name"].as_str()?.to_string()))).filter(|(_, n)| scope.hit(n)).collect();
    if delete {
        for (id, name) in &found {
            tagged(APP, name)?;
            srv.delete_file(ctx, id).await?;
        }
    }
    Ok(found.into_iter().map(|(_, n)| format!("actual file {n}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protobuf_roundtrip() {
        let content = message("transactions", "row-1", "notes", "S:x");
        let ts = timestamp(1_760_341_200_123, 5);
        assert_eq!(ts, "2025-10-13T07:40:00.123Z-0005-e2e0e2e0e2e0e2e0");
        let req = sync_request(&[(ts.clone(), content)], "file", "group", ZERO);
        // a request has the same envelope shape as a response's messages
        let back = response_messages(&req);
        assert_eq!(back, [(ts, "transactions".into(), "row-1".into(), "notes".into(), "S:x".into())]);
        let top: Vec<u32> = fields(&req).iter().map(|(n, _)| *n).collect();
        assert_eq!(top, [1, 2, 3, 6]);
    }

    #[test]
    fn varints_over_127_bytes() {
        let long = "x".repeat(300);
        let m = message("d", "r", "c", &long);
        assert_eq!(fields(&m)[3].1.len(), 300);
    }
}
