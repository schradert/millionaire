---
name: Use existing KUBECONFIG
description: Reuse the KUBECONFIG file created earlier in the session rather than re-fetching or using default
type: feedback
---

When a KUBECONFIG has been created earlier in the session, keep using it via `KUBECONFIG=/path/to/file kubectl ...`. Don't try to re-fetch from sirver or fall back to the default local kubeconfig.

**Why:** User got frustrated when kubeconfig was re-fetched or the wrong one was used after already creating one.

**How to apply:** Track the KUBECONFIG path and prefix all kubectl commands with it for the rest of the session.
