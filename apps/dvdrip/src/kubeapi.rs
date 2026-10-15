//! Small helpers over kube for the Disc and Drive objects.

use anyhow::{Context, Result};
use kube::{
    api::{Patch, PatchParams},
    Api, Client,
};
use serde_json::Value;

use crate::crd::{Disc, Drive};

/// `namespace/name` (or just `name` in `default_ns`).
pub fn split_ref<'a>(r: &'a str, default_ns: &'a str) -> (&'a str, &'a str) {
    r.split_once('/').unwrap_or((default_ns, r))
}

pub async fn discs(ns: &str) -> Result<Api<Disc>> {
    Ok(Api::namespaced(Client::try_default().await.context("connecting to the API server")?, ns))
}

/// Merge-patch a Disc's status.
pub async fn patch_disc_status(api: &Api<Disc>, name: &str, status: Value) -> Result<Disc> {
    api.patch_status(name, &PatchParams::default(), &Patch::Merge(&serde_json::json!({ "status": status })))
        .await
        .with_context(|| format!("updating disc {name}"))
}

pub async fn patch_drive_status(api: &Api<Drive>, name: &str, status: Value) -> Result<Drive> {
    api.patch_status(name, &PatchParams::default(), &Patch::Merge(&serde_json::json!({ "status": status })))
        .await
        .with_context(|| format!("updating drive {name}"))
}

pub fn now() -> String {
    k8s_openapi::jiff::Timestamp::now().to_string()
}
