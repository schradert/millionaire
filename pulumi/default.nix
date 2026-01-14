{
  perSystem.canivete.devenv.shells.default = {pkgs, ...}: {
    packages = [(pkgs.pulumi.withPackages (ps: [ps.pulumi-python]))];
    enterShell = ''
      export PULUMI_ACCESS_TOKEN="$(cat "$DEVENV_ROOT"/secrets/pulumi_token.txt)"
    '';
    languages.python = {
      enable = true;
      directory = "./pulumi";
      uv.enable = true;
      uv.sync.enable = true;
      venv.enable = true;
    };
  };
}
