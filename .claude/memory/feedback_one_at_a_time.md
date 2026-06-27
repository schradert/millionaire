---
name: Don't jump ahead of the user's deploy workflow
description: Wait for the user to deploy changes before checking or debugging further
type: feedback
---

Don't immediately start checking cluster state after making code changes. The user handles the deploy workflow (switch, sync) themselves. Wait for them to confirm they've deployed before investigating cluster state.

**Why:** User got frustrated when debugging was done against old cluster state before they'd had a chance to deploy the changes.

**How to apply:** After making a code change, tell the user what to deploy and wait for them to report back. Don't proactively check pods/logs until they say they've deployed.
