{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.pandoc.enable = can.enable "pandoc toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.pandoc.enable {
      programs.pandoc.enable = true;
      home.packages = with pkgs; [marksman markdownlint-cli2 plantuml pandoc-plantuml-filter];
      programs.doom-emacs = {
        extraBinPackages = with pkgs; [textlint python3Packages.grip];
        tangle.init.lang.markdown = ["+grip"];
        tangle.init.lang.plantuml = true;
      };
    };
  };
}
