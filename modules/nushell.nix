{
  home = {
    config,
    lib,
    pinned,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      programs.nushell.enable = true;
      programs.doom-emacs = {
        # Not on MELPA: explicit recipes, commits pinned in pkgs/nushell-ts-*.
        tangle.packages = ''
          (package! nushell-ts-mode :recipe (:host github :repo "herbertjones/nushell-ts-mode") :pin "${pinned.nushell-ts-mode.pin.version}")
          (package! nushell-ts-babel :recipe (:host github :repo "herbertjones/nushell-ts-babel") :pin "${pinned.nushell-ts-babel.pin.version}")
        '';
        tangle.config = ''
          (after! nushell-ts-mode
            (require 'nushell-ts-babel))
        '';
      };
    };
  };
}
