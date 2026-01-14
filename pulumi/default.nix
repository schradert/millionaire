{
  perSystem.canivete.devenv.shells.default = {
    lib,
    pkgs,
    ...
  }: {
    packages = [(pkgs.pulumi.withPackages (ps: [ps.pulumi-python]))];
    enterShell = ''
      export PULUMI_ACCESS_TOKEN="$(cat "$DEVENV_ROOT"/secrets/pulumi_token.txt)"
    '';
    git-hooks.hooks = {
      mypy.enable = lib.mkForce false;
      ty = {
        enable = true;
        entry = "bash -c 'nix develop --impure --command \"$DEVENV_STATE/venv/bin/ty\" check'";
        types = ["python"];
      };
    };
    languages.python = {
      enable = true;
      directory = "./pulumi";
      uv.enable = true;
      uv.sync.enable = true;
      venv.enable = true;
    };
  };
}
