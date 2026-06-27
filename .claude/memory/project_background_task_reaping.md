---
name: project-background-task-reaping
description: run_in_background tasks get reaped shortly after launch; detach long-lived processes via launchd instead
metadata:
  node_type: memory
  type: project
  originSessionId: 3fd72fa9-dd99-46c9-b66d-9a095ab1fbc6
---

In this Claude Code environment, Bash tasks started with `run_in_background: true` are torn down shortly after launch — the harness marks them "completed (exit 0)" and reaps the process within a turn or two, even when it is provably still alive and doing work. Observed with `caffeinate -dimsu -t 10800` (3h keep-awake): the process held all power assertions when checked, then got killed the instant the task was reported complete.

**Why:** The background-task runner ties the process lifetime to the harness session, not to the command's own duration. A genuinely long-lived process must escape that tree.

**How to apply:** For any process that must outlive the turn (caffeinate, long sleeps, watchers, daemons), do NOT use `run_in_background`. Instead launch it detached as a normal foreground command that returns immediately, so it reparents to `launchd` (PPID 1):
`( nohup <cmd> >/dev/null 2>&1 & ); echo dispatched`
Then verify in a separate call with `pgrep`/`ps -o ppid` (expect PPID 1). Note the command sandbox also silently no-ops `caffeinate` (power assertion can't persist), so pass `dangerouslyDisableSandbox: true` for these.
