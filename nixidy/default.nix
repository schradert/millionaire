{
  imports = [./apps ./system];
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
    options.build.canonicalPackage = can.package "environmentPackage after the vals pass the switch script applies" {internal = true;};
    config = {
      # The committed tree is the output of `switch`: environmentPackage re-serialized by
      # `vals eval` (sorted keys, 0.0 -> 0, no leading blank line in block scalars). This is that
      # same pass as a pure derivation so any Linux builder (tools/render-check) can reproduce it
      # without Pulumi credentials. Files holding ref+pulumistateapi:// refs can't resolve in the
      # sandbox (vals fails, the raw file is kept), which tools/render-check accounts for. The raw
      # environmentPackage differs from the committed tree in serialization only: never diff it.
      build.canonicalPackage = pkgs.runCommand "nixidy-canonical-${config.nixidy.env}" {nativeBuildInputs = [pkgs.vals];} ''
        mkdir $out
        cp -rL ${config.build.environmentPackage}/. $out/
        chmod -R u+w $out
        find $out -name '*.yaml' -type f | while read -r f; do
          if vals eval -f "$f" > "$f.vals" 2>/dev/null; then mv "$f.vals" "$f"; else rm -f "$f.vals"; fi
        done
      '';
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
