---
name: ArgoCD sync and namespace
description: How to sync ArgoCD apps and where they live
type: feedback
---

ArgoCD applications are in the `cicd` namespace (not `argocd`). To sync/refresh an app, use:
`kubectl annotate application <name> -n cicd argocd.argoproj.io/refresh=hard --overwrite`

Don't use patch operations on the application resource to trigger syncs.

**Why:** User corrected the sync method and namespace.

**How to apply:** When deploying or syncing ArgoCD apps, use the annotation approach and `cicd` namespace.
