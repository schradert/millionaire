---
name: Prefer generated themes over pre-made
description: User prefers stylix-generated themes from base16 palette over static/official theme files
type: feedback
---

Prefer generating themes from the stylix base16 palette rather than using pre-made official theme CSS files.
**Why:** User wants consistency across all apps via the central stylix color scheme, and finds the generated approach more maintainable.
**How to apply:** When adding new apps that support theming (CSS, config files), generate the theme from `config.lib.stylix.colors` rather than importing a static theme file. The user loves Dracula theme specifically — stylix is already configured with `dracula.yaml` in `modules/stylix.nix`.
