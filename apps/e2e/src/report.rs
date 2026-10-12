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
    let doc = json!({
        "run": run,
        "kind": kind,
        "summary": { "pass": count("pass"), "fail": count("fail"), "skip": count("skip") },
        "flows": flows.iter().map(Flow::to_json).collect::<Vec<_>>(),
    });
    println!("=== E2E REPORT JSON BEGIN ===");
    println!("{doc}");
    println!("=== E2E REPORT JSON END ===");
}
