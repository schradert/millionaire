---
name: No user-level dotfile dependencies
description: Avoid depending on ~/.docker/config.json or ~/.config/containers/auth.json — use project-local state via devenv files or env vars
type: feedback
---

Don't rely on user-level dotfiles (`~/.docker/config.json`, `~/.config/containers/auth.json`) for tool state like registry auth. Use project-local directories (devenv state/files) or env vars instead.

**Why:** User-level dotfiles are invisible, not reproducible, and conflict across projects. The user wants all state to be project-scoped.

**How to apply:** Use devenv's `files` or `.devenv/state/` for generated config, and `DOCKER_CONFIG`, `REGISTRY_AUTH_FILE`, etc. env vars pointing to project-local paths.
