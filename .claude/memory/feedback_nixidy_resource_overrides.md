---
name: nixidy resource overrides over chart patches
description: Use nixidy resource merging to override K8s fields not supported by Helm chart values, never patch the chart schema/templates
type: feedback
---

Use nixidy `resources.deployments.<name>.spec...` to set Kubernetes fields that the Helm chart doesn't expose in its values schema. Do NOT patch the Helm chart's JSON schema or templates to add missing fields.

**Why:** nixidy handles merging generated Helm output with resource overrides natively. Patching the chart is overkill and fragile. The only exception is when the chart template itself produces wrong output (e.g. wrong apiVersion in a template) — that can't be fixed via resource merging.

**How to apply:** When a Helm chart doesn't support a K8s field (e.g. `pod.subdomain`), set it via `applications.<app>.resources.deployments.<name>.spec.template.spec.<field>` instead of patching the chart.
