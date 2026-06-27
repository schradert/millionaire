---
name: Prefer bun over npm
description: User prefers bun over npm for JavaScript/TypeScript projects. Use bun for package management, builds, and runtime where possible.
type: feedback
---

Prefer bun over npm for JS/TS projects.

**Why:** User preference for speed and developer experience. Has used bun before in Nix but found it required boilerplate.

**How to apply:** When creating JS/TS projects, use bun as the package manager and runtime. Research current nixpkgs support for `buildBunPackage` or equivalent. For devenv, enable `languages.bun` if available, otherwise use bun from nixpkgs. Subprojects should have their own devenv with canivete modules.
