---
name: Use direnv exec for hook management, never call pre-commit directly
description: For millionaire, git-hook/pre-commit tooling is orchestrated by devenv and must be run via `direnv exec .`; calling `pre-commit` directly bypasses devenv's install step.
type: feedback
originSessionId: 8487d328-6732-4d62-9c32-3d1d383bac7d
---
Never invoke `pre-commit` (or similar hook tools) directly. Hook install and regeneration is handled by devenv via `direnv exec .` — the `.envrc` hooks pull in `devenv:git-hooks:install`, which writes `.pre-commit-config.yaml` and installs the hook from the Nix-defined source of truth.

**Why:** The user explicitly called this out as "only work stuff" tooling (Millionaire project) — direnv is the canonical entry point. Hand-calling `pre-commit install` muddies state (installs in "migration mode", leaves stale `core.hooksPath`, desyncs the generated yaml from Nix source). When a commit is blocked by a hook parse error, the fix is editing the Nix source (e.g., `pulumi/default.nix:29` for ruff excludes) and letting devenv regenerate — not editing `.pre-commit-config.yaml` or running pre-commit by hand.

**How to apply:**
- Every commit/push/lint action in this repo: prefix with `direnv exec . <cmd>` (or just `cd` into the dir with direnv active).
- If a hook error mentions pre-commit migration mode or a stale `core.hooksPath`, remove the legacy config (`git config --global --unset core.hooksPath` when it points outside the current worktree) and let direnv re-enter to re-install.
- Fixes to hook config go in the source Nix file (look for `git-hooks.hooks.*` in `devenv.nix` or imported modules), never in the generated yaml.
