{
  perSystem.canivete.devenv.shells.default = {
    config,
    pkgs,
    ...
  }: {
    enterShell = ''
      export PULUMI_ACCESS_TOKEN="$(cat "${config.devenv.root}/secrets/pulumi_token.txt")"
      pulumi stack select prod
    '';
    languages.python.enable = true;
    languages.python.directory = "./pulumi";
    editors.zed.enable = true;
    editors.helix.enable = true;
    treefmt.config.settings.formatter.dprint.options = ["--allow-no-files"];
    packages = [(pkgs.pulumi.withPackages (ps: [ps.pulumi-python]))];
  };
}
