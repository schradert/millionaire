{inputs, ...}: {
  imports = inputs.canivete.canivete.${builtins.currentSystem}.devenv.modules;

  name = "SvelteKit Demo";

  languages.javascript = {
    enable = true;
    bun = {
      enable = true;
      install.enable = true;
    };
  };
  languages.typescript.enable = true;

  # `update-deps` — bump JS deps to the latest their package.json ranges allow
  # and rewrite bun.lock. The Nix-consumed bun.nix is DERIVED from bun.lock via
  # bun2nix and must be regenerated afterward — the exact regen command isn't
  # confirmed yet (tracked in README), so it's not run here to avoid a wrong
  # invocation silently leaving bun.nix stale.
  scripts.update-deps.exec = ''
    set -euo pipefail
    echo "  -> sveltekit-demo (bun)"
    (cd "$DEVENV_ROOT" && bun update)
    echo "  !! Remember to regenerate bun.nix from the new bun.lock (see README bun2nix todo)."
  '';
}
