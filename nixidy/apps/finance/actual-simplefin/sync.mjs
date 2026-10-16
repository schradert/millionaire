// Daily SimpleFIN -> Actual Budget: run by CronJob actual-simplefin with @actual-app/api (the same
// engine the app runs, version-matched to the server), which is the only way to change a budget file
// outside a browser: accounts and transactions live in the budget's own CRDT database, not on the server.
//   1. Sign in with the server (break-glass) password. Nothing here needs the owner's OpenID login.
//   2. Find the budget file: the one named BUDGET_NAME, or the only one there is. None at all: create
//      it (uploaded to the server, visible to every admin). Several and none named BUDGET_NAME: stop.
//   3. List the Bridge accounts (Actual claims the setup token on the first call and keeps the access
//      key) and link each one not linked yet, to a same-named unlinked budget account if there is one,
//      else to a new one. Investments and loans are off budget (tracking accounts), the rest on budget.
//      Each link also imports the last LINK_DAYS days (Bridge: <= 45 recommended per request).
//   4. One batch bank sync for all linked accounts, then sync the file back to the server.
// Bridge requests per run (limit ~24/day, more can disable the token): 1 list + 1 per newly linked
// account + 1 batch sync. Never prints balances, the setup token or the access key.
// Needs an unencrypted budget file: with end-to-end encryption on, the key is the user's, not ours.
import { mkdirSync, readFileSync } from "node:fs";
import * as apiNs from "@actual-app/api";

const api = apiNs.default ?? apiNs;
const env = (k, d) => process.env[k] ?? d;
const url = env("ACTUAL_URL", "http://actual.finance.svc.cluster.local:5006");
const password = readFileSync(env("ADMIN_PASSWORD_FILE", "/secrets/admin/password"), "utf8").trim();
const budgetName = env("BUDGET_NAME", "Budget");
const linkDays = Number(env("LINK_DAYS", "45"));
const dataDir = env("DATA_DIR", "/work/data");

const OFF_BUDGET = /fidelity|empower|guideline|vanguard|schwab|e\*?trade|robinhood|betterment|wealthfront|merrill|voya|prudential|401\(?k|403\(?b|\bira\b|roth|brokerage|retirement|pension|\bhsa\b|529|loan|mortgage|heloc/i;

const log = (m) => console.log(`actual-simplefin: ${m}`);
const fail = (m) => {
  console.error(`actual-simplefin: ${m}`);
  process.exitCode = 1;
};

mkdirSync(dataDir, { recursive: true });
const { send } = await api.init({ serverURL: url, password, dataDir, verbose: false });

async function run() {
  // The engine and the server must be the same release (budget files are versioned): bump package.json
  // together with the actual-server image pin.
  const mine = JSON.parse(readFileSync(new URL("./node_modules/@actual-app/api/package.json", import.meta.url), "utf8")).version;
  const server = (await api.getServerVersion())?.version;
  if (server !== mine) throw new Error(`server is ${server}, @actual-app/api is ${mine}: bump package.json to match the actual-server pin`);

  const status = await send("simplefin-status");
  if (!status?.configured) {
    log("no SimpleFIN token on the server (set actual/simplefin/token in Bitwarden); nothing to do");
    return;
  }

  const files = (await api.getBudgets()).filter((b) => b.groupId && !/^e2e-/.test(b.name ?? ""));
  let file = files.find((b) => b.name === budgetName) ?? (files.length === 1 ? files[0] : undefined);
  if (file) {
    await api.downloadBudget(file.groupId);
    log(`using budget "${file.name}"`);
  } else if (files.length === 0) {
    const created = await send("create-budget", { budgetName });
    if (created?.error) throw new Error(`could not create the budget: ${created.error}`);
    // create-budget swallows an upload failure; the budget must be on the server or it is lost with this pod.
    file = (await api.getBudgets()).find((b) => b.name === budgetName && b.groupId);
    if (!file) throw new Error("the new budget did not upload to the server");
    log(`created budget "${budgetName}"`);
  } else {
    throw new Error(`${files.length} budgets and none named "${budgetName}": set BUDGET_NAME`);
  }

  const res = await send("simplefin-accounts");
  const external = res?.accounts;
  if (!Array.isArray(external)) {
    throw new Error(`could not list the Bridge accounts: ${res?.error_code ?? res?.error ?? res?.error_type ?? "unknown"} ${res?.reason ?? ""}`);
  }

  const existing = await send("accounts-get");
  const linked = new Set(existing.filter((a) => a.account_sync_source === "simpleFin" && !a.tombstone).map((a) => a.account_id));
  const startingDate = new Date(Date.now() - linkDays * 864e5).toISOString().slice(0, 10);

  let added = 0;
  for (const a of external) {
    if (linked.has(a.id)) continue;
    const institution = a.org?.name ?? a.org?.domain ?? "SimpleFIN";
    const label = `${institution} - ${a.name}`;
    const offBudget = OFF_BUDGET.test(`${institution} ${a.name}`);
    const lower = new Set([a.name, label].map((n) => n.toLowerCase()));
    const mine = existing.find((x) => !x.account_sync_source && !x.closed && !x.tombstone && lower.has(String(x.name).toLowerCase()));
    const upgradingId = mine?.id ?? (await send("account-create", { name: label, offBudget, balance: 0 }));
    const out = await send("simplefin-accounts-link", {
      externalAccount: { account_id: a.id, name: a.name, institution, orgDomain: a.org?.domain, orgId: a.org?.id },
      upgradingId,
      offBudget,
      startingDate,
    });
    if (out !== "ok") throw new Error(`linking "${label}" failed: ${JSON.stringify(out).slice(0, 200)}`);
    log(`linked ${label} (${offBudget ? "off" : "on"} budget${mine ? ", existing account" : ""})`);
    added++;
  }
  log(`${external.length} Bridge accounts, ${added} newly linked`);

  // One batch call = one Bridge request. api.runBankSync() would add a request per account: its
  // second pass takes an empty id list to mean "all accounts" when every account is SimpleFIN.
  const ids = (await send("accounts-get")).filter((a) => a.account_sync_source === "simpleFin" && !a.closed && !a.tombstone).map((a) => a.id);
  const synced = ids.length ? await send("simplefin-batch-sync", { ids }) : [];
  const errors = synced.flatMap((s) => s.res?.errors ?? []).filter(Boolean);
  const fresh = synced.reduce((n, s) => n + (s.res?.newTransactions?.length ?? 0), 0);
  log(`bank sync: ${ids.length} accounts, ${fresh} new transactions, ${errors.length} errors`);
  for (const e of errors) fail(`bank sync error ${e.category ?? ""} ${e.code ?? ""} ${e.message ?? ""}`);
  await api.sync();
}

try {
  await run();
} catch (e) {
  fail(`${e.message ?? e}`);
} finally {
  await api.shutdown().catch(() => {});
}
