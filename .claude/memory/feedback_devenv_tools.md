---
name: Always use devenv for tools
description: Never install tools directly with nix run/nix-shell/comma. Always configure them in the relevant devenv.nix and enter via direnv exec.
type: feedback
---

Never install tools via `nix run`, `nix-shell`, or comma (`, <tool>`). All development tools must come from the devenv configuration.

**Why:** The user wants all tooling to be declarative and reproducible through devenv. Running tools ad-hoc bypasses the development environment contract.

**How to apply:** For any tool needed in a subproject, add it to that subproject's `devenv.nix` via `languages.*` options or `packages = [...]`. Then use `direnv exec <path> <command>` to run tools. Let `bun.install.enable = true` auto-install node_modules on shell entry rather than running install commands manually.
