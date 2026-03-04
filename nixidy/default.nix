{
  imports = [./apps ./system];
  devenv = {
    git-hooks.excludes = ["nixidy/generated"];
    git-hooks.hooks.lychee.toml.exclude = ["^.+\\.svc$"];
  };
  nixidy = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: let
    pulumi = {
      vals = resourceType: logicalName: attributeKey: let
        encodedType = lib.replaceStrings ["/" ":"] ["__" "_"] resourceType;
        # FIXME why doesn't pkgs.fromYAML exist to parse Pulumi.yaml for project name?
        params = builtins.concatStringsSep "&" [
          "organization=pulumbus"
          "project=millionaire"
          "stack=${config.nixidy.env}"
        ];
      in
        builtins.concatStringsSep "/" [
          "ref+pulumistateapi:/"
          encodedType
          logicalName
          "outputs"
          "${attributeKey}?${params}+"
        ];
    };
  in {
    options.build.scripts.switch = can.package "command to switch cluster manifests" {internal = true;};
    config = {
      _module.args.pulumi = pulumi;
      nixidy.target = {
        repository = "https://github.com/schradert/millionaire.git";
        rootPath = "./nixidy/generated/${config.nixidy.env}";
        branch = "main";
      };
      build.scripts.switch = pkgs.writeShellApplication {
        # Vals needs to run in the project root to read pulumi state
        name = "nixidy-switch-${config.nixidy.env}";
        runtimeInputs = [
          pkgs.git
          config.build.scripts.nixidy
          pkgs.vals
          pkgs.parallel
        ];
        text = ''
          cd "$(git rev-parse --show-toplevel)"
          nixidy switch ".#${config.nixidy.env}"
          find "${config.nixidy.target.rootPath}" -name "*.yaml" -type f | \
            parallel 'vals eval -f {} > {}.tmp && mv {}.tmp {}'
        '';
      };
    };
  };
}
