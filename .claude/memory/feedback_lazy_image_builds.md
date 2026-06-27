---
name: Lazy image builds
description: Container images must not build on devshell entry — use runtime nix build/run, not embedded store paths
type: feedback
---

Never embed nix2container image derivation paths (`${img.copyToRegistry}/bin/...`) in devshell scripts. This forces images to build when entering the shell, which is extremely slow for Linux cross-builds on macOS.

**Why:** The first attempt used a devenv `images` option with `attrsOf package` where push scripts embedded store paths. Entering the devshell triggered cross-builds of `linuxPkgs.home-assistant` via the Linux builder before the user could get a prompt.

**How to apply:** Define images as `perSystem.legacyPackages.images` (flake packages). Devshell scripts call `nix build`/`nix run` at runtime with the flake attribute path. Only image *names* (strings) are known at eval time — derivations are evaluated lazily when the user explicitly runs `image build <name>`.
