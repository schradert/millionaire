{config, ...}: let
  inherit (config.canivete.sops) default;
in {
  canivete.pkgs.allowUnfree = ["bws"];
  devenv = {
    config,
    pkgs,
    ...
  }: {
    enterShell = ''
      export PULUMI_ACCESS_TOKEN="$(cat "${config.devenv.root}/secrets/pulumi_token.txt")"
      export CLOUDFLARE_API_TOKEN="$(cat "${config.devenv.root}/secrets/cloudflare_token.txt")"
      export BWS_ACCESS_TOKEN="$(cd "${config.devenv.root}" && sops --decrypt --extract '["bitwarden"]' "${default}")"
      pulumi stack select prod
    '';
    languages.python.enable = true;
    languages.python.directory = "./pulumi";
    editors.zed.enable = true;
    editors.helix.enable = true;
    treefmt.config.settings.formatter.dprint.options = ["--allow-no-files"];
    packages = with pkgs; [
      bws
      (pkgs.pulumi.withPackages (ps: [ps.pulumi-python]))
    ];
    git-hooks.hooks.ruff.excludes = ["pulumi/sdks/**"];
  };
}
