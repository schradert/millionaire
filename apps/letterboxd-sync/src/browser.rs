//! The only part that touches letterboxd.com: sign in as the owner, upload one CSV on the import
//! page, confirm it. It follows the site's own pages the way a person would (typing, clicking,
//! pausing between steps) and never reads anything beyond them. It does not try to get past a bot
//! check: if one appears the run stops.

use chromiumoxide::browser::{Browser, BrowserConfig};
use chromiumoxide::cdp::browser_protocol::dom::SetFileInputFilesParams;
use chromiumoxide::page::{Page, ScreenshotParams};
use futures::StreamExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub struct Site {
    pub base: String,
    pub username: String,
    pub password: String,
    pub chromium: PathBuf,
    /// Pause between steps, milliseconds (min, max). Zero in tests.
    pub pace_ms: (u64, u64),
    /// How long to wait for the success text after the confirm click.
    pub confirm_wait_secs: u64,
    /// Where a screenshot and the page HTML go when a step fails.
    pub debug_dir: PathBuf,
}

pub struct Session {
    site: Site,
    browser: Browser,
    task: tokio::task::JoinHandle<()>,
    page: Page,
    seed: u64,
    profile: PathBuf,
}

/// What the confirm click led to.
pub enum Confirmed {
    /// The page said the import was accepted.
    Done(String),
    /// The click happened but no known success text appeared. The caller must treat the diary as
    /// possibly changed.
    Unrecognised(String),
}

const SUCCESS: &str =
    r"(imported|import (is )?(complete|completed|finished|successful|done|in progress|running|queued)|successfully|films? (have been |were )?added)";
const BOT_CHECK: &str = r"(just a moment|verify you are human|checking your browser|captcha|attention required)";

fn js_str(s: &str) -> String {
    serde_json::to_string(s).expect("string")
}

impl Session {
    pub async fn open(site: Site) -> Result<Session, String> {
        let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let profile = std::env::temp_dir().join(format!("lbx-profile-{}-{nonce}", std::process::id()));
        let config = BrowserConfig::builder()
            .chrome_executable(&site.chromium)
            .user_data_dir(&profile)
            .no_sandbox()
            .window_size(1280, 900)
            .arg("--disable-gpu")
            .arg("--disable-dev-shm-usage")
            .build()?;
        let (browser, mut handler) = Browser::launch(config).await.map_err(|e| format!("launch chromium {}: {e}", site.chromium.display()))?;
        let task = tokio::spawn(async move { while handler.next().await.is_some() {} });
        let page = browser.new_page("about:blank").await.map_err(|e| format!("new page: {e}"))?;
        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1) | 1;
        Ok(Session { site, browser, task, page, seed, profile })
    }

    pub async fn close(mut self) {
        let _ = self.browser.close().await;
        let _ = self.browser.wait().await;
        self.task.abort();
        let _ = tokio::fs::remove_dir_all(&self.profile).await;
    }

    async fn pace(&mut self) {
        let (lo, hi) = self.site.pace_ms;
        if hi == 0 {
            return;
        }
        self.seed ^= self.seed << 13;
        self.seed ^= self.seed >> 7;
        self.seed ^= self.seed << 17;
        tokio::time::sleep(Duration::from_millis(lo + self.seed % (hi.saturating_sub(lo) + 1))).await;
    }

    async fn text(&self) -> String {
        self.page.evaluate("document.body ? document.body.innerText : ''").await.ok().and_then(|v| v.into_value::<String>().ok()).unwrap_or_default()
    }

    async fn truthy(&self, js: &str) -> bool {
        self.page.evaluate(js).await.ok().and_then(|v| v.into_value::<bool>().ok()).unwrap_or(false)
    }

    async fn wait_until(&self, js: &str, secs: u64) -> bool {
        let end = Instant::now() + Duration::from_secs(secs);
        while Instant::now() < end {
            if self.truthy(js).await {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        false
    }

    async fn bot_check(&self) -> bool {
        self.truthy(&format!("new RegExp({}, 'i').test(document.body ? document.body.innerText + ' ' + document.title : '')", js_str(BOT_CHECK))).await
    }

    /// Save a screenshot and the HTML next to the state so a failed step can be read afterwards.
    pub async fn dump(&self, tag: &str) {
        let _ = tokio::fs::create_dir_all(&self.site.debug_dir).await;
        if let Ok(png) = self.page.screenshot(ScreenshotParams::builder().full_page(true).build()).await {
            let _ = tokio::fs::write(self.site.debug_dir.join(format!("{tag}.png")), png).await;
        }
        if let Ok(html) = self.page.content().await {
            let _ = tokio::fs::write(self.site.debug_dir.join(format!("{tag}.html")), html).await;
        }
    }

    async fn goto(&mut self, path: &str) -> Result<(), String> {
        let url = format!("{}{path}", self.site.base.trim_end_matches('/'));
        self.page.goto(url.as_str()).await.map_err(|e| format!("open {url}: {e}"))?;
        self.pace().await;
        if self.bot_check().await {
            self.dump("bot-check").await;
            return Err(format!("{url} shows a bot check; not trying to get past it (see the debug dump)"));
        }
        Ok(())
    }

    async fn type_into(&mut self, selector: &str, text: &str) -> Result<(), String> {
        let el = self.page.find_element(selector).await.map_err(|e| format!("no {selector} on the page: {e}"))?;
        el.click().await.map_err(|e| format!("click {selector}: {e}"))?;
        self.pace().await;
        el.type_str(text).await.map_err(|e| format!("type into {selector}: {e}"))?;
        self.pace().await;
        Ok(())
    }

    async fn step<T>(&self, tag: &str, r: Result<T, String>) -> Result<T, String> {
        if r.is_err() {
            self.dump(tag).await;
        }
        r
    }

    pub async fn login(&mut self) -> Result<(), String> {
        self.goto("/sign-in/").await?;
        let r = self.login_form().await;
        self.step("login", r).await?;
        self.goto("/import/").await?;
        let ok = self.truthy("!!document.querySelector('input[type=file]') && !document.querySelector('input[type=password]')").await;
        if !ok {
            self.dump("import-page").await;
            return Err("the import page has no file input (not signed in, or the page changed)".into());
        }
        Ok(())
    }

    async fn login_form(&mut self) -> Result<(), String> {
        if !self.wait_until("!!document.querySelector('input[name=username]')", 20).await {
            return Err("sign-in form not found".into());
        }
        let (user, pass) = (self.site.username.clone(), self.site.password.clone());
        self.type_into("input[name=username]", &user).await?;
        self.type_into("input[name=password]", &pass).await?;
        let pw = self.page.find_element("input[name=password]").await.map_err(|e| e.to_string())?;
        pw.press_key("Enter").await.map_err(|e| format!("submit: {e}"))?;
        let left = self
            .wait_until("!document.querySelector('input[name=password]') || /(incorrect|invalid|wrong|didn.t match)/i.test(document.body.innerText)", 30)
            .await;
        if !left {
            return Err("still on the sign-in form after 30 s".into());
        }
        if self.bot_check().await {
            return Err("a bot check followed the sign-in; not trying to get past it".into());
        }
        if self.truthy("!!document.querySelector('input[name=password]')").await {
            return Err("sign-in refused (wrong username or password?)".into());
        }
        Ok(())
    }

    /// Choose the CSV on the import page and wait for the page to offer the confirm step. Returns
    /// the page's own summary text.
    pub async fn upload(&mut self, csv: &Path) -> Result<String, String> {
        let before = self
            .page
            .evaluate(
                "JSON.stringify([...document.querySelectorAll('button,input[type=submit],a.button,a.btn')].map(e => (e.innerText || e.value || '').trim()))",
            )
            .await
            .ok()
            .and_then(|v| v.into_value::<String>().ok())
            .unwrap_or_else(|| "[]".into());
        let r = self.choose_file(csv).await;
        self.step("upload", r).await?;
        self.pace().await;
        let appeared = format!(
            "(() => {{ const old = {}; const el = [...document.querySelectorAll('button,input[type=submit],a.button,a.btn')].find(e => {{ const t = (e.innerText || e.value || '').trim(); return /(import|confirm)/i.test(t) && !old.includes(t); }}); if (!el) return false; el.setAttribute('data-robot-target', '1'); return true; }})()",
            before
        );
        if !self.wait_until(&appeared, 60).await {
            self.dump("no-confirm").await;
            return Err("the import page never offered a confirm step after the upload".into());
        }
        let summary = self.text().await.chars().take(800).collect::<String>();
        self.dump("summary").await;
        Ok(summary)
    }

    async fn choose_file(&mut self, csv: &Path) -> Result<(), String> {
        let el = self.page.find_element("input[type=file]").await.map_err(|e| format!("no file input: {e}"))?;
        let params =
            SetFileInputFilesParams::builder().files(vec![csv.display().to_string()]).node_id(el.node_id).build().map_err(|e| format!("file params: {e}"))?;
        self.page.execute(params).await.map_err(|e| format!("set file: {e}"))?;
        Ok(())
    }

    /// The point of no return: Letterboxd has no undo after this click.
    pub async fn confirm(&mut self) -> Result<Confirmed, String> {
        self.pace().await;
        let el = self.page.find_element("[data-robot-target]").await.map_err(|e| format!("confirm button gone: {e}"))?;
        el.click().await.map_err(|e| format!("click confirm: {e}"))?;
        let done = format!("new RegExp({}, 'i').test(document.body.innerText)", js_str(SUCCESS));
        let ok = self.wait_until(&done, self.site.confirm_wait_secs).await;
        let text = self.text().await.chars().take(800).collect::<String>();
        self.dump("confirmed").await;
        Ok(if ok { Confirmed::Done(text) } else { Confirmed::Unrecognised(text) })
    }
}
