---
name: Pulumi runs are manual only
description: Never run pulumi up automatically — user always runs it themselves
type: feedback
---

Never run `pulumi up` automatically. The user always runs Pulumi manually.

**Why:** User preference for control over infrastructure changes.

**How to apply:** When Pulumi changes are needed (new secrets, resources), note what needs to be run but don't execute it. The user will handle `cd pulumi && pulumi up --yes` themselves.
