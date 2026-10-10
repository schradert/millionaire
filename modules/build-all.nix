# Every buildable output native to a system, as legacyPackages.<system>.build-all
# (built by the devenv `build-all` script). Attribute names never force a
# config, so one broken host can't hide the rest from nix-eval-jobs.
{
  inputs,
  lib,
  ...
}: let
  inherit (inputs) self;
  inherit (self.canivete.deploy) nodes;
  sets = lib.mapAttrs (_: lib.recurseIntoAttrs);
  # The dev host and the cluster; aarch64-linux (voron) only builds its host.
  consumer = system: lib.elem system ["aarch64-darwin" "x86_64-linux"];
  hostSystem = name: nodes.${name}.canivete.system or self.nixosConfigurations.${name}.pkgs.stdenv.hostPlatform.system;
in {
  perSystem = {system, ...}: let
    ofSystem = lib.filterAttrs (name: _: hostSystem name == system);
    lp = self.legacyPackages.${system};
  in {
    legacyPackages.build-all = sets ({
        hosts =
          lib.mapAttrs (_: c: c.config.system.build.toplevel) (ofSystem self.nixosConfigurations)
          // lib.mapAttrs (_: c: c.system) (ofSystem self.darwinConfigurations);
        deploy = lib.concatMapAttrs (node: n:
          lib.mapAttrs' (p: v: lib.nameValuePair "${node}-${p}" v.path) (removeAttrs n.profiles ["system"]))
        (ofSystem self.deploy.nodes);
      }
      // lib.optionalAttrs (consumer system) {
        # devenv's container-* outputs need an mk-shell-bin input nothing uses.
        packages = removeAttrs self.packages.${system} ["container-processes" "container-shell"];
        pinned = lib.filterAttrs (_: lib.isDerivation) lp.pinned;
        charts = lp.pinned.charts;
        devShells = self.devShells.${system};
        nixidy = lib.mapAttrs (_: e: e.environmentPackage) lp.nixidyEnvs.${system};
      }
      // lib.optionalAttrs (system == "x86_64-linux") {
        images = lp.images;
      });
  };
}
