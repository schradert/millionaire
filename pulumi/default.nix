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
    git-hooks.hooks = let
      # Force to use uv-pinned library rather than from nixpkgs
      exec = exe: args: "bash -c 'nix develop --impure --command \"$DEVENV_STATE/venv/bin/${exe}\" ${args}'";
    in {
      ruff.entry = lib.mkForce (exec "ruff" "check --fix");
      ruff-format.entry = lib.mkForce (exec "ruff" "format");
      # TODO why is taplo freezing with this pin?
      # taplo.entry = lib.mkForce (exec "taplo" "fmt");
      # Much better type checker
      mypy.enable = lib.mkForce false;
      ty = {
        enable = true;
        entry = exec "ty" "check";
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
