//! Baikal (sabre/dav) as a CalDAV/CardDAV client uses it: the bootstrapped DAV user creates a
//! tagged calendar and address book (never the `org` calendar org-bridge writes to), puts an
//! event and a contact, finds them with REPORT queries, deletes them and checks they are gone.

use crate::trace::SendTraced as _;
use super::dav::{elements, unescape, Dav};
use crate::{
    ctx::{need_secret, Ctx, Fail, Scope, R},
    report::Flow,
    svc::{tagged, url},
};

const APP: &str = "baikal";
const USER: &str = "admin";

fn dav() -> R<Dav> {
    Ok(Dav::new(&url("BAIKAL_URL", "cal"), USER, &need_secret(APP, "e2e-baikal", "password")?))
}

fn cal_path(marker: &str) -> String {
    format!("/dav.php/calendars/{USER}/{marker}-cal/")
}

fn book_path(marker: &str) -> String {
    format!("/dav.php/addressbooks/{USER}/{marker}-book/")
}

pub fn event_ics(marker: &str) -> String {
    format!("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//e2e//EN\r\nBEGIN:VEVENT\r\nUID:{marker}@e2e\r\nDTSTAMP:20261013T000000Z\r\nDTSTART:20261101T100000Z\r\nDTEND:20261101T110000Z\r\nSUMMARY:{marker} meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
}

pub fn contact_vcf(marker: &str) -> String {
    format!("BEGIN:VCARD\r\nVERSION:3.0\r\nUID:{marker}@e2e\r\nFN:{marker} Contact\r\nN:Contact;E2E;;;\r\nEMAIL:{marker}@e2e.trdos.me\r\nEND:VCARD\r\n")
}

const XML: (&str, &str) = ("Content-Type", "application/xml; charset=utf-8");

fn mkcalendar(marker: &str) -> String {
    format!(r#"<?xml version="1.0" encoding="utf-8"?><c:mkcalendar xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:"><d:set><d:prop><d:displayname>{marker}-cal</d:displayname><c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set></d:prop></d:set></c:mkcalendar>"#)
}

fn mkbook(marker: &str) -> String {
    format!(r#"<?xml version="1.0" encoding="utf-8"?><d:mkcol xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><card:addressbook/></d:resourcetype><d:displayname>{marker}-book</d:displayname></d:prop></d:set></d:mkcol>"#)
}

fn calendar_query(marker: &str) -> String {
    format!(r#"<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:"><d:prop><d:getetag/><c:calendar-data/></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:prop-filter name="SUMMARY"><c:text-match collation="i;octet">{marker}</c:text-match></c:prop-filter></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"#)
}

fn addressbook_query(marker: &str) -> String {
    format!(r#"<?xml version="1.0" encoding="utf-8"?><card:addressbook-query xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:d="DAV:"><d:prop><d:getetag/><card:address-data/></d:prop><card:filter><card:prop-filter name="FN"><card:text-match collation="i;unicode-casemap" match-type="contains">{marker}</card:text-match></card:prop-filter></card:filter></card:addressbook-query>"#)
}

const PROPFIND: &str = r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>"#;

/// Collection hrefs under `home` (the user's calendars or address books).
async fn collections(ctx: &Ctx, dav: &Dav, home: &str) -> R<Vec<String>> {
    let body = dav.ok(ctx, APP, "PROPFIND", home, &[("Depth", "1"), XML], Some(PROPFIND)).await?;
    Ok(elements(&body, "href").into_iter().map(|h| unescape(&h)).filter(|h| h.trim_end_matches('/') != home.trim_end_matches('/')).collect())
}

pub async fn dav_roundtrip(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let dav = dav()?;
    let m = tagged(APP, &ctx.marker)?;

    // `.well-known` discovery: what a client starts from.
    let wk = ctx.noredir.get(format!("{}/.well-known/caldav", url("BAIKAL_URL", "cal"))).send_t().await;
    if let Ok(r) = wk {
        let loc = r.headers().get("location").and_then(|v| v.to_str().ok()).unwrap_or("");
        if !r.status().is_redirection() || !loc.contains("/dav.php") {
            return Err(Fail::new(APP, "well-known caldav", format!("HTTP {} location {loc:?}, expected a redirect to /dav.php", r.status())));
        }
        f.ok(APP, "/.well-known/caldav", format!("redirects to {loc}"));
    }

    let cal = cal_path(m);
    dav.ok(ctx, APP, "MKCALENDAR", &cal, &[XML], Some(&mkcalendar(m))).await?;
    f.ok(APP, "calendar created", format!("{m}-cal"));
    dav.ok(ctx, APP, "PUT", &format!("{cal}{m}.ics"), &[("Content-Type", "text/calendar; charset=utf-8")], Some(&event_ics(m))).await?;
    let found = dav.ok(ctx, APP, "REPORT", &cal, &[("Depth", "1"), XML], Some(&calendar_query(m))).await?;
    let data: String = elements(&found, "calendar-data").iter().map(|d| unescape(d)).collect();
    if !data.contains(&format!("UID:{m}@e2e")) || !data.contains(&format!("SUMMARY:{m} meeting")) {
        return Err(Fail::new(APP, "calendar-query", format!("the tagged event is not in the REPORT: {}", crate::ctx::excerpt(&found))));
    }
    f.ok(APP, "event found by REPORT", "calendar-query on SUMMARY");

    let book = book_path(m);
    dav.ok(ctx, APP, "MKCOL", &book, &[XML], Some(&mkbook(m))).await?;
    f.ok(APP, "address book created", format!("{m}-book"));
    dav.ok(ctx, APP, "PUT", &format!("{book}{m}.vcf"), &[("Content-Type", "text/vcard; charset=utf-8")], Some(&contact_vcf(m))).await?;
    let found = dav.ok(ctx, APP, "REPORT", &book, &[("Depth", "1"), XML], Some(&addressbook_query(m))).await?;
    let data: String = elements(&found, "address-data").iter().map(|d| unescape(d)).collect();
    if !data.contains(&format!("FN:{m} Contact")) || !data.contains(&format!("EMAIL:{m}@e2e.trdos.me")) {
        return Err(Fail::new(APP, "addressbook-query", format!("the tagged contact is not in the REPORT: {}", crate::ctx::excerpt(&found))));
    }
    f.ok(APP, "contact found by REPORT", "addressbook-query on FN");
    Ok(())
}

/// Delete the event and the contact, and check the queries no longer find them.
pub async fn items_deleted(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let dav = dav()?;
    let m = &ctx.marker;
    let (cal, book) = (cal_path(m), book_path(m));
    dav.delete(ctx, APP, &format!("{cal}{m}.ics")).await?;
    let found = dav.ok(ctx, APP, "REPORT", &cal, &[("Depth", "1"), XML], Some(&calendar_query(m))).await?;
    if found.contains(m.as_str()) && found.contains("SUMMARY") {
        return Err(Fail::new(APP, "event deleted", "the REPORT still returns the event"));
    }
    dav.delete(ctx, APP, &format!("{book}{m}.vcf")).await?;
    let found = dav.ok(ctx, APP, "REPORT", &book, &[("Depth", "1"), XML], Some(&addressbook_query(m))).await?;
    if found.contains("FN:") {
        return Err(Fail::new(APP, "contact deleted", "the REPORT still returns the contact"));
    }
    f.ok(APP, "event and contact deleted", "REPORTs return nothing");
    Ok(())
}

/// Delete the flow's calendar and address book, and check both are gone.
pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let dav = dav()?;
    let m = &ctx.marker;
    for p in [cal_path(m), book_path(m)] {
        dav.delete(ctx, APP, &p).await?;
    }
    let left = tagged_collections(ctx, &dav, &Scope::Run(m.clone())).await?;
    if !left.is_empty() {
        return Err(Fail::new(APP, "collections deleted", left.join(", ")));
    }
    f.ok(APP, "calendar and address book deleted", "PROPFIND lists neither");
    Ok(())
}

async fn tagged_collections(ctx: &Ctx, dav: &Dav, scope: &Scope) -> R<Vec<String>> {
    let mut out = Vec::new();
    for home in [format!("/dav.php/calendars/{USER}/"), format!("/dav.php/addressbooks/{USER}/")] {
        out.extend(collections(ctx, dav, &home).await?.into_iter().filter(|h| scope.hit(h)));
    }
    Ok(out)
}

/// Family sweep and residue: tagged calendars and address books of the DAV user.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let dav = dav()?;
    let found = tagged_collections(ctx, &dav, scope).await?;
    if delete {
        for h in &found {
            dav.delete(ctx, APP, h).await?;
        }
    }
    Ok(found.into_iter().map(|h| format!("baikal {h}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bodies_carry_the_marker() {
        let m = "e2e-20261013-000000-abcd";
        assert!(event_ics(m).contains("UID:e2e-20261013-000000-abcd@e2e") && event_ics(m).ends_with("\r\n"));
        assert!(contact_vcf(m).contains("FN:e2e-20261013-000000-abcd Contact"));
        assert!(cal_path(m).contains(m) && book_path(m).contains(m));
        assert!(calendar_query(m).contains(m) && addressbook_query(m).contains(m));
    }
}
