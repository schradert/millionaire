{
  perSystem.canivete.devenv.shells.default = {pkgs, ...}: {
    treefmt.config.settings.formatter.dprint.options = ["--allow-no-files"];
    packages = [(pkgs.pulumi.withPackages (ps: [ps.pulumi-python]))];
    languages.python = {
      enable = true;
      directory = "./pulumi";
      uv.enable = true;
      uv.sync.enable = true;
      venv.enable = true;
    };
  };
}
