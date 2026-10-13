//! Per-flow results: pass/fail/skip, timing, steps, and the failing app and step.

use std::time::Instant;

use serde_json::{json, Value};

use crate::ctx::{Fail, R};

pub struct Step {
    pub phase: &'static str,
    pub app: String,
    pub name: String,
    pub detail: String,
    pub ms: u128,
}

pub struct Flow {
    pub family: String,
    pub name: String,
    /// The phase (setup, act, assert, cleanup) steps are recorded under.
    pub phase: &'static str,
    pub steps: Vec<Step>,
    started: Instant,
    last: Instant,
    pub ms: u128,
    pub outcome: Option<Result<(), Fail>>,
}

impl Flow {
    pub fn new(name: &str) -> Self {
        let now = Instant::now();
        Flow {
            family: String::new(),
            name: name.into(),
            phase: "",
            steps: Vec::new(),
            started: now,
            last: now,
            ms: 0,
            outcome: None,
        }
    }

    /// Record a passed step.
    pub fn ok(&mut self, app: &str, name: &str, detail: impl Into<String>) {
        let detail = detail.into();
        println!("  [{}] {app}: {name} ok {detail}", self.name);
        self.steps.push(Step {
            phase: self.phase,
            app: app.into(),
            name: name.into(),
            detail,
            ms: self.last.elapsed().as_millis(),
        });
        self.last = Instant::now();
    }

    pub fn finish(&mut self, res: R<()>) {
        self.ms = self.started.elapsed().as_millis();
        match &res {
            Ok(()) => println!("[{}] PASS ({} ms)", self.name, self.ms),
            Err(f) if f.skip => println!("[{}] SKIP {}: {}: {}", self.name, f.app, f.step, f.msg),
            Err(f) => println!("[{}] FAIL {}: {}: {}", self.name, f.app, f.step, f.msg),
        }
        self.outcome = Some(res);
    }

    pub fn status(&self) -> &'static str {
        match &self.outcome {
            Some(Ok(())) => "pass",
            Some(Err(f)) if f.skip => "skip",
            Some(Err(_)) => "fail",
            None => "not-run",
        }
    }

    pub fn to_json(&self) -> Value {
        let err = match &self.outcome {
            Some(Err(f)) => json!({ "app": f.app, "step": f.step, "message": f.msg }),
            _ => Value::Null,
        };
        json!({
            "family": self.family,
            "flow": self.name,
            "status": self.status(),
            "ms": self.ms as u64,
            "error": err,
            "steps": self.steps.iter().map(|s| json!({ "phase": s.phase, "app": s.app, "step": s.name, "detail": s.detail, "ms": s.ms as u64 })).collect::<Vec<_>>(),
        })
    }
}

/// The report document: run id, kind, counts and every flow.
pub fn document(run: &str, kind: &str, flows: &[Flow]) -> Value {
    let count = |s: &str| flows.iter().filter(|f| f.status() == s).count();
    json!({
        "run": run,
        "kind": kind,
        "summary": { "pass": count("pass"), "fail": count("fail"), "skip": count("skip") },
        "flows": flows.iter().map(Flow::to_json).collect::<Vec<_>>(),
    })
}

/// A ConfigMap manifest holding the report (`report.json`) and its headline (`run`, `kind`,
/// `result`, `summary`), so the last result can be read without any Job or Pod being around. A
/// document over ~900 KB loses its per-flow steps (a ConfigMap holds 1 MiB).
pub fn configmap(ns: &str, name: &str, doc: &Value) -> Value {
    let mut text = doc.to_string();
    if text.len() > 900_000 {
        let mut slim = doc.clone();
        for f in slim["flows"].as_array_mut().into_iter().flatten() {
            f["steps"] = Value::Null;
        }
        text = slim.to_string();
    }
    let failed = doc["summary"]["fail"].as_u64().unwrap_or(0) > 0;
    json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": { "name": name, "namespace": ns, "labels": { "app.kubernetes.io/name": "e2e-report" } },
        "data": {
            "report.json": text,
            "run": doc["run"].as_str().unwrap_or_default(),
            "kind": doc["kind"].as_str().unwrap_or_default(),
            "result": if failed { "fail" } else { "pass" },
            "summary": doc["summary"].to_string(),
            "finished": crate::ctx::rfc3339(crate::ctx::unix_now()),
        },
    })
}

/// Keep the report of this run in the ConfigMap `$E2E_REPORT_CONFIGMAP` (`<namespace>/<name>`),
/// replacing the previous one. Best effort: the run's result never depends on it.
pub async fn save(doc: &Value) {
    let Some((ns, name)) = std::env::var("E2E_REPORT_CONFIGMAP").ok().and_then(|v| v.split_once('/').map(|(a, b)| (a.to_string(), b.to_string()))) else {
        return;
    };
    let path = std::env::temp_dir().join("e2e-report-configmap.json");
    let bin = std::env::var("E2E_KUBECTL").unwrap_or_else(|_| "kubectl".into());
    let res = async {
        std::fs::write(&path, configmap(&ns, &name, doc).to_string()).map_err(|e| e.to_string())?;
        let out = tokio::process::Command::new(bin).args(["apply", "-f"]).arg(&path).output().await.map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
        }
    }
    .await;
    let _ = std::fs::remove_file(&path);
    match res {
        Ok(()) => println!("report saved in configmap {ns}/{name}"),
        Err(e) => println!("report NOT saved in configmap {ns}/{name}: {e}"),
    }
}

pub fn print(run: &str, kind: &str, flows: &[Flow]) {
    println!();
    println!("{:<10} {:<26} {:<6} {:>8}  FAILING APP / STEP / REASON", "FAMILY", "FLOW", "RESULT", "SECONDS");
    for f in flows {
        let why = match &f.outcome {
            Some(Err(e)) => format!("{} / {} / {}", e.app, e.step, e.msg),
            _ => String::new(),
        };
        println!("{:<10} {:<26} {:<6} {:>8.1}  {}", f.family, f.name, f.status().to_uppercase(), f.ms as f64 / 1000.0, why);
    }
    let count = |s: &str| flows.iter().filter(|f| f.status() == s).count();
    println!("pass {}  fail {}  skip {}", count("pass"), count("fail"), count("skip"));
    println!("=== E2E REPORT JSON BEGIN ===");
    println!("{}", document(run, kind, flows));
    println!("=== E2E REPORT JSON END ===");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configmap_carries_the_headline_and_the_document() {
        let mut ok = Flow::new("a");
        ok.finish(Ok(()));
        let mut bad = Flow::new("b");
        bad.finish(Err(Fail::new("app", "step", "why")));
        let doc = document("20260101-000000-aaaa", "offline", &[ok, bad]);
        let cm = configmap("e2e", "e2e-last-report", &doc);
        assert_eq!(cm["metadata"]["namespace"], "e2e");
        assert_eq!(cm["data"]["result"], "fail");
        assert_eq!(cm["data"]["run"], "20260101-000000-aaaa");
        assert_eq!(cm["data"]["summary"], r#"{"fail":1,"pass":1,"skip":0}"#);
        let back: Value = serde_json::from_str(cm["data"]["report.json"].as_str().unwrap()).unwrap();
        assert_eq!(back["flows"][1]["error"]["message"], "why");
    }

    #[test]
    fn oversized_reports_lose_their_steps_not_their_verdicts() {
        let mut f = Flow::new("big");
        f.ok("app", "step", "x".repeat(1_000_000));
        f.finish(Ok(()));
        let cm = configmap("e2e", "r", &document("20260101-000000-aaaa", "full", &[f]));
        let text = cm["data"]["report.json"].as_str().unwrap();
        assert!(text.len() < 10_000);
        assert_eq!(cm["data"]["result"], "pass");
    }
}
