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
{
  inputs,
  lib,
  ...
}: {
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
          version = "0.2.0";
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
          tag = app.version;
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
          # 1.13.4 (latest) looks devices up via `device_registry.devices[...]`,
          # which HA 2026.9 rejects: its send_gcode/custom-gcode services fail
          # at runtime, the rest of the integration works.
          (moonraker.overridePythonAttrs (old: {
            disabledTests =
              (old.disabledTests or [])
              ++ [
                "test_set_custom_gcode_service"
                "test_send_gcode_list_payload_normalizes_script"
                "test_send_gcode_empty_payload_skips_send"
                "test_send_gcode_accepts_config_entry_id_and_deduplicates"
              ];
          }))
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
          version = (builtins.fromTOML (builtins.readFile "${src}/Cargo.toml")).package.version;
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
          version = (builtins.fromTOML (builtins.readFile "${src}/Cargo.toml")).package.version;
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

      # Per-user single sign-on sidecar for Seerr (apps/seerr-sso, nixidy/apps/media/seerr.nix).
      seerr-sso = let
        amd64Pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
        src = ../apps/seerr-sso;
        pkg = amd64Pkgs.rustPlatform.buildRustPackage {
          pname = "seerr-sso";
          version = (builtins.fromTOML (builtins.readFile "${src}/Cargo.toml")).package.version;
          inherit src;
          cargoLock.lockFile = "${src}/Cargo.lock";
        };
      in
        n2c.buildImage {
          name = "${registry}/library/seerr-sso";
          tag = pkg.version;
          arch = "amd64";
          config.Entrypoint = ["${pkg}/bin/seerr-sso"];
          layers = [(n2c.buildLayer {deps = [pkg];})];
        };

      # Trakt to Letterboxd import robot (apps/letterboxd-sync, nixidy/apps/media/letterboxd-sync.nix,
      # docs/scrobbling.md): a Rust binary driving the nixpkgs Chromium over its DevTools socket.
      letterboxd-sync = let
        amd64Pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
        src = ../apps/letterboxd-sync;
        pkg = amd64Pkgs.rustPlatform.buildRustPackage {
          pname = "letterboxd-sync";
          version = (builtins.fromTOML (builtins.readFile "${src}/Cargo.toml")).package.version;
          inherit src;
          cargoLock.lockFile = "${src}/Cargo.lock";
          # The flow tests need a Chromium on CHROMIUM_PATH and loopback servers; the pre-push hooks run them.
          doCheck = false;
        };
        chromium = amd64Pkgs.chromium;
      in
        n2c.buildImage {
          name = "${registry}/library/letterboxd-sync";
          tag = pkg.version;
          arch = "amd64";
          config = {
            Entrypoint = ["${pkg}/bin/letterboxd-sync"];
            Env = ["HOME=/tmp" "CHROMIUM_PATH=${chromium}/bin/chromium" "SSL_CERT_FILE=${amd64Pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"];
          };
          layers = [
            (n2c.buildLayer {deps = [chromium amd64Pkgs.cacert];})
            (n2c.buildLayer {deps = [pkg];})
          ];
        };

      # Platform end-to-end tests (apps/e2e), run as a Job from a suspended `e2e` CronJob
      # (nixidy/apps/media/media-e2e.nix for the media family, nixidy/apps/e2e.nix for the rest).
      # kubectl is for `exec` into the qbittorrent pod (VPN leak tests) and the storage flows (tagged Pods, PVCs and snapshots in `e2e`), git for the git family.
      # Replaces library/media-e2e (<= 0.1.8): publish it, then
      # add pkgs/images/e2e/pin.json (the shape of media-e2e's, repository library/e2e).
      e2e = let
        amd64Pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
        src = ../apps/e2e;
        pkg = amd64Pkgs.rustPlatform.buildRustPackage {
          pname = "e2e";
          version = (builtins.fromTOML (builtins.readFile "${src}/Cargo.toml")).package.version;
          inherit src;
          cargoLock.lockFile = "${src}/Cargo.lock";
          # Some unit tests bind loopback servers and run git, which the build sandbox cannot do
          # (the feed and git server tests fail there); the pre-push hooks run them.
          doCheck = false;
        };
      in
        n2c.buildImage {
          name = "${registry}/library/e2e";
          tag = pkg.version;
          arch = "amd64";
          config = {
            Entrypoint = ["${pkg}/bin/e2e"];
            Env = ["PATH=${amd64Pkgs.kubectl}/bin:${amd64Pkgs.git}/bin" "HOME=/tmp" "GIT_SSL_CAINFO=${amd64Pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"];
          };
          layers = [
            (n2c.buildLayer {deps = [amd64Pkgs.kubectl amd64Pkgs.git amd64Pkgs.cacert];})
            (n2c.buildLayer {deps = [pkg];})
          ];
        };

      # DVD ripping (apps/dvdrip, docs/dvd-rip.md): agent, controller, encode and publish Jobs, with
      # the media tools on PATH. Stock nixpkgs: NVENC needs no CUDA build (HandBrake dlopens the
      # driver the GPU pod gets from the container toolkit).
      dvdrip = let
        amd64Pkgs = import inputs.nixpkgs {
          system = "x86_64-linux";
          config.allowUnfreePredicate = p: lib.getName p == "makemkv";
        };
        src = ../apps/dvdrip;
        pkg = amd64Pkgs.rustPlatform.buildRustPackage {
          pname = "dvdrip";
          version = (builtins.fromTOML (builtins.readFile "${src}/Cargo.toml")).package.version;
          inherit src;
          cargoLock.lockFile = "${src}/Cargo.lock";
          # The parity tests read the recorded discs in tests/fixtures.
          doCheck = true;
        };
        tools = with amd64Pkgs; [
          bashInteractive
          coreutils
          findutils
          gnugrep
          handbrake
          makemkv
          ddrescue
          dvdbackup
          lsdvd
          cdrkit
          dvdauthor # dvdrip synth (e2e)
          mkvtoolnix-cli
          ffmpeg-full
          util-linux
          systemd
          regionset
          cacert
        ];
      in
        n2c.buildImage {
          name = "${registry}/library/dvdrip";
          tag = pkg.version;
          arch = "amd64";
          config = {
            Entrypoint = ["${pkg}/bin/dvdrip"];
            Env = [
              "PATH=${lib.makeBinPath tools}"
              "LD_LIBRARY_PATH=${amd64Pkgs.libdvdcss}/lib"
              "HOME=/tmp"
              "SSL_CERT_FILE=${amd64Pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
          };
          layers = [
            (n2c.buildLayer {deps = tools ++ [amd64Pkgs.libdvdcss];})
            (n2c.buildLayer {deps = [pkg];})
          ];
        };

      # Monthly backup verification (apps/backup-verify, nixidy/system/storage/backup-verify.nix):
      # restic check, scratch VolSync + CNPG restores, etcd snapshot age. Bump the tag with the script.
      backup-verify = let
        amd64Pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
        tools = with amd64Pkgs; [bash coreutils findutils gawk gnugrep gnused jq curl restic kubectl cacert];
        script = amd64Pkgs.writeShellApplication {
          name = "backup-verify";
          runtimeInputs = tools;
          bashOptions = []; # the script handles every status itself (no errexit)
          # the script is long-lived shell with deliberate unquoted splitting; syntax-check only
          checkPhase = "${amd64Pkgs.bash}/bin/bash -n $target";
          text = builtins.readFile ../apps/backup-verify/backup-verify.sh;
        };
      in
        n2c.buildImage {
          name = "${registry}/library/backup-verify";
          tag = "0.2.1";
          arch = "amd64";
          config = {
            Entrypoint = ["${script}/bin/backup-verify"];
            Env = ["HOME=/tmp" "SSL_CERT_FILE=${amd64Pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"];
          };
          layers = [
            (n2c.buildLayer {deps = tools;})
            (n2c.buildLayer {deps = [script];})
          ];
        };

      # Weekly Bitwarden Secrets Manager backup (apps/bws-backup, nixidy/system/security/bws-backup.nix):
      # bws list, age-encrypted, uploaded to B2. bws is unfree.
      bws-backup = let
        amd64Pkgs = import inputs.nixpkgs {
          system = "x86_64-linux";
          config.allowUnfreePredicate = p: lib.getName p == "bws";
        };
        tools = with amd64Pkgs; [bash coreutils jq bws age rclone cacert];
        script = amd64Pkgs.writeShellApplication {
          name = "bws-backup";
          runtimeInputs = tools;
          text = builtins.readFile ../apps/bws-backup/bws-backup.sh;
        };
      in
        n2c.buildImage {
          name = "${registry}/library/bws-backup";
          tag = "0.1.0";
          arch = "amd64";
          config = {
            Entrypoint = ["${script}/bin/bws-backup"];
            Env = ["HOME=/tmp" "SSL_CERT_FILE=${amd64Pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"];
          };
          layers = [
            (n2c.buildLayer {deps = tools;})
            (n2c.buildLayer {deps = [script];})
          ];
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
            KC_TRACING_ENABLED = "true";
            # Build-time too: parent-based keeps the sampled traces of callers like e2e (the default ignores them).
            KC_TRACING_SAMPLER_TYPE = "parentbased_traceidratio";
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
          # -N: the build options (tracing-enabled, tracing-sampler-type) are baked in; a new N is a new tag, so it is published
          tag = "${dist.version}-optimized-2";
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

      # org-bridge: org files <-> CalDAV reconciliation worker. amd64 as above.
      org-bridge = let
        amd64Pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
        src = ../org-bridge;
        pkg = amd64Pkgs.rustPlatform.buildRustPackage {
          pname = "org-bridge";
          version = "0.1.0";
          inherit src;
          cargoLock.lockFile = "${src}/Cargo.lock";
          nativeBuildInputs = [amd64Pkgs.pkg-config];
          buildInputs = [amd64Pkgs.openssl];
        };
      in
        n2c.buildImage {
          name = "${registry}/library/org-bridge";
          # -1: adds busybox (the Deployment's exec probe runs `sh -c test -f`)
          tag = "${pkg.version}-1";
          arch = "amd64";
          config = {
            Entrypoint = ["${pkg}/bin/org-bridge"];
            Env = [
              "PATH=${amd64Pkgs.busybox}/bin"
              "SSL_CERT_FILE=${amd64Pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
          };
          layers = [(n2c.buildLayer {deps = [pkg amd64Pkgs.cacert amd64Pkgs.busybox];})];
        };

      # mooncord: Moonraker Discord bot, no upstream image (pkgs/mooncord). Takes its
      # config dir as argv[0] (<dir>/mooncord.cfg), not env vars. amd64 as above.
      mooncord = let
        amd64Pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
        pins = import ../lib/pins.nix {inherit lib;};
        mkPinned = import ../pkgs {
          inherit lib pins;
          kubelib = inputs.nixidy.inputs.nix-kube-generators.lib;
        };
        pkg = (mkPinned amd64Pkgs).mooncord;
        root = amd64Pkgs.runCommand "mooncord-root" {} "mkdir -p $out/tmp $out/config";
      in
        n2c.buildImage {
          name = "${registry}/library/mooncord";
          tag = pkg.version;
          arch = "amd64";
          config = {
            User = "1000";
            WorkingDir = "/config";
            Entrypoint = ["${amd64Pkgs.nodejs_22}/bin/node" "${pkg}/lib/mooncord/dist/index.js"];
            Cmd = ["/config"];
            Env = [
              "PATH=${amd64Pkgs.ffmpeg-headless}/bin"
              "SSL_CERT_FILE=${amd64Pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
            Volumes."/config" = {};
          };
          copyToRoot = [root];
          perms = [
            {
              path = root;
              regex = "/tmp";
              mode = "1777";
            }
            {
              path = root;
              regex = "/config";
              mode = "0777";
            }
          ];
          layers = [(n2c.buildLayer {deps = [pkg amd64Pkgs.nodejs_22 amd64Pkgs.ffmpeg-headless amd64Pkgs.cacert];})];
        };

      # rsync daemon for the one-time bulk ingest (nixidy/apps/media/archive-ingest.nix); the
      # Deployment mounts its rsyncd.conf and secrets at /config. amd64 as above.
      rsyncd = let
        amd64Pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
        root = amd64Pkgs.runCommand "rsyncd-root" {} "mkdir -p $out/tmp";
      in
        n2c.buildImage {
          name = "${registry}/library/rsyncd";
          tag = amd64Pkgs.rsync.version;
          arch = "amd64";
          config = {
            Entrypoint = ["${amd64Pkgs.rsync}/bin/rsync" "--daemon" "--no-detach" "--config=/config/rsyncd.conf"];
            ExposedPorts."873/tcp" = {};
          };
          copyToRoot = [root];
          perms = [
            {
              path = root;
              regex = "/tmp";
              mode = "1777";
            }
          ];
          layers = [(n2c.buildLayer {deps = [amd64Pkgs.rsync];})];
        };

      # Coder workspace base (apps/workspace, nixidy/apps/development/coder). Bump the tag with the image.
      workspace = import ../apps/workspace/image.nix {inherit inputs n2c registry;};

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
