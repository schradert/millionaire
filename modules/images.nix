# Container image build framework using nix2container.
#
# Images are exposed as flake packages under `legacyPackages.<system>.images.<name>`.
# The devshell `image` script invokes `nix build`/`nix run` at runtime so nothing
# builds when entering the shell.
#
# Usage from devshell:
#   image list              — show available images
#   image build <name>      — build an image locally
#   image publish <name>    — build and push to Harbor
#   image publish --all     — push all images
{inputs, ...}: {
  perSystem = {system, ...}: let
    linuxSystem = builtins.replaceStrings ["darwin"] ["linux"] system;
    n2c = inputs.nix2container.packages.${system}.nix2container;
    linuxPkgs = import inputs.nixpkgs {system = linuxSystem;};
    bun2nix = inputs.bun2nix.lib.${linuxSystem};
    registry = "harbor.trdos.me";
  in {
    # Image definitions — add new images here
    legacyPackages.images = {
      sveltekit-demo = let
        bunDeps = bun2nix.fetchBunDeps {
          bunNix = ../apps/sveltekit-demo/bun.nix;
        };
        app = linuxPkgs.stdenvNoCC.mkDerivation {
          pname = "sveltekit-demo";
          version = "0.1.0";
          src = ../apps/sveltekit-demo;
          nativeBuildInputs = [linuxPkgs.bun linuxPkgs.nodejs_22];
          configurePhase = ''
            runHook preConfigure
            cp -r ${bunDeps}/node_modules node_modules
            chmod -R u+w node_modules
            runHook postConfigure
          '';
          buildPhase = ''
            runHook preBuild
            bun run build
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r build $out/build
            cp package.json $out/
            # Production deps only
            cp -r node_modules $out/
            runHook postInstall
          '';
        };
      in
        n2c.buildImage {
          name = "${registry}/library/sveltekit-demo";
          tag = "latest";
          config = {
            Cmd = ["${linuxPkgs.nodejs_22}/bin/node" "/app/build"];
            WorkingDir = "/app";
            ExposedPorts."3000/tcp" = {};
            Env = ["NODE_ENV=production" "PORT=3000" "HOST=0.0.0.0"];
          };
          copyToRoot = [
            (linuxPkgs.runCommand "sveltekit-demo-root" {} ''
              mkdir -p $out/app
              cp -r ${app}/* $out/app/
            '')
          ];
          layers = [
            (n2c.buildLayer {deps = [linuxPkgs.nodejs_22];})
            (n2c.buildLayer {deps = [app];})
          ];
        };

      ha = let
        customComponents = with linuxPkgs.home-assistant-custom-components; [
          adaptive_lighting
          alarmo
          auth_oidc
          better_thermostat
          frigate
          gpio
          moonraker
          ntfy
          prometheus_sensor
          samsungtv-smart
          scene_presets
          smartir
          spook
          versatile_thermostat
          waste_collection_schedule
        ];
        customComponentsDir = linuxPkgs.runCommand "ha-custom-components" {} (
          ''
            mkdir -p $out/custom_components
          ''
          + builtins.concatStringsSep "\n" (map (
              comp: ''
                for dir in ${comp}/lib/python*/site-packages/custom_components/*/; do
                  name=$(basename "$dir")
                  ln -s "$dir" "$out/custom_components/$name"
                done
              ''
            )
            customComponents)
        );
      in
        n2c.buildImage {
          name = "${registry}/library/ha";
          tag = linuxPkgs.home-assistant.version;
          config = {
            Cmd = ["${linuxPkgs.home-assistant}/bin/hass" "--config" "/config"];
            ExposedPorts."8123/tcp" = {};
            Volumes."/config" = {};
          };
          layers = [
            (n2c.buildLayer {deps = [linuxPkgs.home-assistant];})
            (n2c.buildLayer {
              deps = customComponents;
              copyToRoot = [customComponentsDir];
            })
          ];
        };

      # Post-sync bootstrap Job for jellyfin (wizard, admin user, libraries).
      # Pinned to x86_64: every cluster node is amd64, but linuxPkgs above follows
      # the build host (aarch64-linux on the Mac), which would give an arm64 image.
      jellyfin-bootstrap = let
        amd64Pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
        src = ../apps/jellyfin-bootstrap;
        pkg = amd64Pkgs.rustPlatform.buildRustPackage {
          pname = "jellyfin-bootstrap";
          version = "0.2.0";
          inherit src;
          cargoLock.lockFile = "${src}/Cargo.lock";
        };
      in
        n2c.buildImage {
          name = "${registry}/library/jellyfin-bootstrap";
          tag = pkg.version;
          arch = "amd64";
          config.Entrypoint = ["${pkg}/bin/jellyfin-bootstrap"];
          layers = [(n2c.buildLayer {deps = [pkg];})];
        };

      # First-run bootstrap for apps without their own (immich, kavita): one image,
      # `app-bootstrap <app>`. Pinned to x86_64 for the same reason as above.
      app-bootstrap = let
        amd64Pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
        src = ../apps/app-bootstrap;
        pkg = amd64Pkgs.rustPlatform.buildRustPackage {
          pname = "app-bootstrap";
          version = "0.2.0";
          inherit src;
          cargoLock.lockFile = "${src}/Cargo.lock";
        };
      in
        n2c.buildImage {
          name = "${registry}/library/app-bootstrap";
          tag = pkg.version;
          arch = "amd64";
          config.Entrypoint = ["${pkg}/bin/app-bootstrap"];
          layers = [(n2c.buildLayer {deps = [pkg];})];
        };

      govee2mqtt = n2c.buildImage {
        name = "${registry}/library/govee2mqtt";
        tag = linuxPkgs.govee2mqtt.version;
        config = {
          Cmd = ["${linuxPkgs.govee2mqtt}/bin/govee" "serve"];
          Env = ["XDG_CACHE_HOME=/data" "RUST_BACKTRACE=full"];
          Volumes."/data" = {};
        };
        layers = [(n2c.buildLayer {deps = [linuxPkgs.govee2mqtt];})];
      };
    };
  };
}
