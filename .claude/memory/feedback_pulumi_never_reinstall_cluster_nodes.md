---
name: pulumi-never-reinstall-cluster-nodes
description: "Pulumi ups for hyena/image work must be --target scoped; nixos-*-install must never re-run on live cluster nodes (sirver, octopus, dingo, bonobo, chinchilla)"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 9b142a34-2241-45c3-9d7d-3c51bd4421b7
---

When running `pulumi up` for hyena / Hetzner-image work, scope with `--target` (+ `--target-dependents` where needed) so the live cluster nodes (sirver, octopus, dingo, bonobo, chinchilla) are untouched. Their `nixos-<name>-install` resources must NEVER re-run — a re-install kexecs a live RKE2 node back into the installer and wipes it.

**Why:** Install resources are protected by `ignore_changes=["create"]` and have no triggers, but two vectors can still fire them: (1) renaming/restructuring resources in `pulumi/millionaire/nixos.py` gives them new URNs — pulumi treats that as delete+create and re-runs the install command; (2) an untargeted `pulumi up` replaces `nixos-*-deploy` resources whenever node toplevels drift, pushing untested config to the k8s fleet (see [[no-untested-infrastructure-changes]]).

**How to apply:** Before any `pulumi up`, run `pulumi preview` and verify no `nixos-{sirver,octopus,dingo,bonobo,chinchilla}-install` resource shows create/replace. Keep existing resource names stable when refactoring the NixOS class. For hyena-scoped work always use `pulumi up --target <hyena URNs> --target-dependents`.
