{
  # nixpkgs godot is linux-only; darwin gets the cask.
  darwin = {
    config,
    lib,
    ...
  }: {
    homebrew.casks = lib.mkIf config.profiles.languages.enable ["godot"];
  };
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.godot.enable = can.enable "godot toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.godot.enable {
      home.packages = [pkgs.gdtoolkit_4] ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.godot;
      programs.doom-emacs.tangle.init.lang.gdscript = ["+lsp"];
    };
  };
}
