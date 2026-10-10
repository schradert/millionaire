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
    bun2nix = inputs.bun2nix.packages.${linuxSystem}.default;
    registry = "harbor.trdos.me";
  in {
    # Image definitions — add new images here
    legacyPackages.images = {
      sveltekit-demo = let
        app = linuxPkgs.stdenvNoCC.mkDerivation {
          pname = "sveltekit-demo";
          version = "0.1.0";
          src = ../apps/sveltekit-demo;
          nativeBuildInputs = [bun2nix.hook linuxPkgs.nodejs_22];
          bunDeps = bun2nix.fetchBunDeps {
            bunNix = ../apps/sveltekit-demo/bun.nix;
          };
          # A plain node_modules tree to copy into the image.
          bunInstallFlags = ["--linker=hoisted"];
          buildPhase = ''
            runHook preBuild
            bun run build
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r build package.json $out/
            cp -rL node_modules $out/
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
          version = "0.3.0";
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
          version = "0.7.0";
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

      # Keycloak with its build-time options baked in, so it boots `--optimized`.
      # The stock image re-augments on every start (chmod over every lib jar, an
      # overlay copy-up of ~285MB), which on a disk-saturated node outlived the
      # startup probe (2026-10-10). Base: the pinned upstream image; the only added
      # layer is lib/quarkus from `kc.sh build` on the same release's dist.
      keycloak = let
        base = builtins.fromJSON (builtins.readFile ../pkgs/images/keycloak/pin.json);
        dist = builtins.fromJSON (builtins.readFile ../pkgs/keycloak-dist/pin.json);
        # Bytecode only, so the build host's own pkgs are fine.
        hostPkgs = import inputs.nixpkgs {inherit system;};
        augmented = hostPkgs.stdenvNoCC.mkDerivation {
          pname = "keycloak-augmented";
          inherit (dist) version;
          src = hostPkgs.fetchurl {
            url = builtins.replaceStrings ["{version}"] [dist.version] dist.source.url;
            inherit (dist) hash;
          };
          # Must match the Deployment's KC_* build options (nixidy/apps/identity/keycloak.nix),
          # or `start --optimized` refuses to run.
          env = {
            KC_DB = "postgres";
            KC_HEALTH_ENABLED = "true";
            KC_METRICS_ENABLED = "true";
            KC_FEATURES = "hostname:v2";
          };
          buildPhase = ''
            patchShebangs bin
            JAVA_HOME=${hostPkgs.jdk21_headless} bin/kc.sh build
          '';
          installPhase = ''
            mkdir -p $out/opt/keycloak/lib
            cp -r lib/quarkus $out/opt/keycloak/lib/
          '';
        };
      in
        n2c.buildImage {
          name = "${registry}/library/keycloak";
          tag = "${dist.version}-optimized";
          arch = "amd64";
          fromImage = n2c.pullImage {
            imageName = base.source.repository;
            imageDigest = base.digest;
            sha256 = base.hashes.nix2container;
            arch = "amd64";
          };
          copyToRoot = [augmented];
          # Not inherited from fromImage.
          config = {
            User = "1000";
            WorkingDir = "/";
            Entrypoint = ["/opt/keycloak/bin/kc.sh"];
            Cmd = ["start" "--optimized"];
            Env = [
              "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
              "LANG=en_US.UTF-8"
              "KC_RUN_IN_CONTAINER=true"
            ];
            ExposedPorts = {
              "8080/tcp" = {};
              "8443/tcp" = {};
              "9000/tcp" = {};
            };
          };
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
