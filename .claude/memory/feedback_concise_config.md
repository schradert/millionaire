---
name: feedback_concise_config
description: Keep gatus endpoint definitions and similar config entries concise (one-line url assignments)
type: feedback
---

When adding config entries like gatus endpoints, keep them as succinct as possible — just define the url on one line. Don't add extra fields like custom names unless asked.

**Why:** User prefers minimal, clean config entries. Custom names can be added later if needed.
**How to apply:** For gatus endpoints, use `gatus.endpoints.<name>.url = "https://...";` for auto-detected group, or `gatus.endpoints.<name> = { url = "..."; group = "..."; };` when group must be explicit.
