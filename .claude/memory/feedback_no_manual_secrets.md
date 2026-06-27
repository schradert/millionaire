---
name: No manual secret creation
description: Never create K8s secrets manually — all secrets must flow through automated pipelines (Pulumi → Bitwarden → ExternalSecrets, or operator-managed)
type: feedback
---

Never use `kubectl create secret` or any manual secret creation. All secrets must be automatically generated and propagated through the established pipeline.

**Why:** Manual secrets are not reproducible, not tracked, and break the declarative model. The user wants a fully automated secret lifecycle.

**How to apply:** When a secret is needed, either:
1. Generate it in Pulumi → store in Bitwarden → ExternalSecret syncs to K8s
2. Have an operator create it (e.g., KeycloakClient clientSecretRef, CNPG postgres credentials)
3. If an operator feature doesn't work as documented, investigate and fix the root cause rather than working around it with manual steps
