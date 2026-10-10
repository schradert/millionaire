# Per-language toolchains: modules/languages/<name>.nix each declare
# `languages.<name>.enable` (default: profiles.languages.enable, itself on for
# workstations) and contribute packages (on PATH for helix too) + Doom modules.
{
  home = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.languages.enable {
      programs.doom-emacs.tangle.init.tools = {
        lsp = ["+peek"];
        tree-sitter = true;
        debugger = true;
      };
    };
  };
}
