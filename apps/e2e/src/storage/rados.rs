//! Object storage: an ObjectBucketClaim on the `ceph-bucket` class makes Rook create a bucket and
//! an RGW user, and a Secret and ConfigMap named like the claim carry the credentials and the
//! bucket. The flow puts, lists, gets and deletes one tagged object through the gateway's route
//! (`rados.<domain>`) with those credentials, then deletes the claim (the bucket and user go with it).

use std::time::Duration;

use reqwest::Method;
use serde_json::{json, Value};

use super::s3::{path, S3};
use crate::{
    ctx::{domain, find_marker, poll, var, At, Ctx, Fail, R},
    kube,
    report::Flow,
};

const APP: &str = "rados";

fn claim(ctx: &Ctx) -> String {
    format!("{}-rados", ctx.marker)
}

/// The claim: Rook's provisioner names the bucket `<generateBucketName>-<random>`.
pub fn obc(name: &str, class: &str) -> Value {
    json!({
        "apiVersion": "objectbucket.io/v1alpha1", "kind": "ObjectBucketClaim", "metadata": kube::meta(name),
        "spec": { "generateBucketName": name, "storageClassName": class },
    })
}

async fn data(kind: &str, name: &str, key: &str) -> R<String> {
    kube::kubectl(&["get", kind, name, "-o", &format!("go-template={{{{index .data \"{key}\"{}}}}}", if kind == "secret" { " | base64decode" } else { "" })])
        .await
}

pub async fn object(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let name = claim(ctx);
    let class = var("E2E_BUCKET_CLASS", "ceph-bucket");
    kube::create(ctx, &obc(&name, &class)).await?;
    f.ok(APP, "ObjectBucketClaim created", format!("{name} (class {class})"));
    poll(APP, "claim is Bound", Duration::from_secs(180), Duration::from_secs(3), || async {
        let o = kube::get("objectbucketclaim", &name).await?.at(APP, "claim vanished")?;
        Ok((o["status"]["phase"] == "Bound").then_some(()))
    })
    .await?;
    let bucket = data("configmap", &name, "BUCKET_NAME").await?;
    if find_marker(&bucket).is_none() {
        return Err(Fail::new(APP, "bucket name", format!("{bucket} does not carry the run marker")));
    }
    let region = data("configmap", &name, "BUCKET_REGION").await.ok().filter(|r| !r.is_empty() && r != "<no value>").unwrap_or_else(|| "us-east-1".into());
    let s3 = S3 {
        endpoint: var("E2E_S3_ENDPOINT", &format!("https://rados.{}", domain())),
        access_key: data("secret", &name, "AWS_ACCESS_KEY_ID").await?,
        secret_key: data("secret", &name, "AWS_SECRET_ACCESS_KEY").await?,
        region,
    };
    f.ok(APP, "bucket provisioned", format!("{bucket}; credentials read from the claim's Secret"));

    let key = format!("{}.txt", ctx.marker);
    let text = format!("e2e {} object", ctx.marker);
    let obj = path(&bucket, &key);
    let (st, body) = s3.request(ctx, Method::PUT, &obj, &[], text.clone().into_bytes()).await?;
    if !(200..300).contains(&st) {
        return Err(Fail::new(APP, "PUT object", format!("HTTP {st}: {}", crate::ctx::excerpt(&body))));
    }
    f.ok(APP, "PUT object", key.clone());
    let (st, body) = s3.request(ctx, Method::GET, &obj, &[], vec![]).await?;
    if st != 200 || body != text {
        return Err(Fail::new(APP, "GET object", format!("HTTP {st}, body {}", crate::ctx::excerpt(&body))));
    }
    f.ok(APP, "GET returns the content", "equal");
    let (st, body) = s3.request(ctx, Method::GET, &path(&bucket, ""), &[("list-type", "2"), ("prefix", &ctx.marker)], vec![]).await?;
    if st != 200 || !body.contains(&key) {
        return Err(Fail::new(APP, "list objects", format!("HTTP {st}, {key} not listed: {}", crate::ctx::excerpt(&body))));
    }
    f.ok(APP, "list shows the object", "");
    let (st, _) = s3.request(ctx, Method::DELETE, &obj, &[], vec![]).await?;
    if !(200..300).contains(&st) {
        return Err(Fail::new(APP, "DELETE object", format!("HTTP {st}")));
    }
    let (st, _) = s3.request(ctx, Method::GET, &obj, &[], vec![]).await?;
    if st != 404 {
        return Err(Fail::new(APP, "GET after delete", format!("HTTP {st}, expected 404")));
    }
    f.ok(APP, "DELETE removes the object", "GET is 404");
    Ok(())
}

/// Empty the bucket (an object left by a failed flow would stop the provisioner deleting it),
/// delete the claim, and wait for its Secret and ConfigMap to go with it.
pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let name = claim(ctx);
    if let (Ok(bucket), Ok(ak), Ok(sk)) =
        (data("configmap", &name, "BUCKET_NAME").await, data("secret", &name, "AWS_ACCESS_KEY_ID").await, data("secret", &name, "AWS_SECRET_ACCESS_KEY").await)
    {
        let s3 = S3 { endpoint: var("E2E_S3_ENDPOINT", &format!("https://rados.{}", domain())), access_key: ak, secret_key: sk, region: "us-east-1".into() };
        // Best effort: the object normally is deleted already.
        let _ = s3.request(ctx, Method::DELETE, &path(&bucket, &format!("{}.txt", ctx.marker)), &[], vec![]).await;
    }
    kube::delete(&[("objectbucketclaim".into(), name.clone())]).await?;
    for kind in ["secret", "configmap"] {
        poll(APP, &format!("{kind} {name} is removed with the claim"), Duration::from_secs(120), Duration::from_secs(3), || async {
            Ok(kube::get(kind, &name).await?.is_none().then_some(()))
        })
        .await?;
    }
    f.ok(APP, "claim deleted; Secret and ConfigMap gone", name);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claim_is_tagged_and_names_the_class() {
        let c = obc("e2e-20260101-000000-aaaa-rados", "ceph-bucket");
        assert_eq!(c["metadata"]["namespace"], "e2e");
        assert_eq!(c["metadata"]["labels"]["app.kubernetes.io/name"], "e2e-test");
        assert_eq!(c["spec"]["storageClassName"], "ceph-bucket");
        assert_eq!(c["spec"]["generateBucketName"], "e2e-20260101-000000-aaaa-rados");
    }
}
