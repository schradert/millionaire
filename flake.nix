{
  description = "";
  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };
  inputs = {
    # Development
    canivete.url = "github:schradert/canivete";
    canivete.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-parts.follows = "flake-parts";
    };
    # home-manager (below) tracks master to pair with nixos-unstable; move both
    # to a release branch together.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    devenv.url = "github:cachix/devenv";
    devenv-agents.url = "github:cachix/devenv-ai-agents";
    devenv-agents.flake = false;
    bun2nix.url = "github:nix-community/bun2nix";
    bun2nix.inputs.nixpkgs.follows = "nixpkgs";
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";

    # Systems
    deploy-rs.url = "github:serokell/deploy-rs";
    # Deliberately NOT following our nixpkgs: deploy-rs is a self-contained
    # Rust binary, and pinning it to our nixpkgs commit makes its activate-rs
    # binary a cache miss everywhere (cache.nixos.org only caches the canonical
    # upstream-pinned version). Letting deploy-rs use its own pinned nixpkgs
    # means we get the prebuilt binary from cache, avoiding a ~10 min rustc
    # bootstrap build on every fresh target (which has also been observed to
    # exhaust sshd/nix-daemon resource limits mid-build and crash the deploy).
    # The extra nixpkgs version costs a few hundred MB of disk on hosts that
    # already deploy a lot — a fair trade for cache hits.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
    # Needed for nixos-raspberrypi right now
    # TODO follow merge of https://github.com/NixOS/nixpkgs/pull/398456
    nixos-raspberrypi.inputs.nixpkgs.url = "github:schradert/nixpkgs/nixos-unstable-398456";
    # TODO submit feature upstream
    # nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.url = "github:schradert/nixos-anywhere";
    nixos-anywhere.inputs = {
      flake-parts.follows = "flake-parts";
      nixpkgs.follows = "nixpkgs";
      disko.follows = "disko";
      # treefmt-nix.follows = "treefmt";
    };
    nixos-facter-modules.url = "github:nix-community/nixos-facter-modules";
    # Phones (gargoyle); a plain NixOS module tree, imported by device name
    mobile-nixos.url = "github:mobile-nixos/mobile-nixos";
    mobile-nixos.flake = false;
    nixos-wsl.url = "github:nix-community/NixOS-WSL";
    nixos-wsl.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-compat.follows = "flake-compat";
    };
    # Steam Deck. Tracks nixos-unstable; move it with nixpkgs.
    jovian.url = "github:Jovian-Experiments/Jovian-NixOS";
    jovian.inputs.nixpkgs.follows = "nixpkgs";
    # mkWindowsApp (wine prefixes for Windows-only games), called with our pkgs
    erosanix.url = "github:emmanuelrosa/erosanix";
    erosanix.flake = false;
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    srvos.url = "github:nix-community/srvos";
    srvos.inputs.nixpkgs.follows = "nixpkgs";

    # Programs
    helix.url = "github:helix-editor/helix";
    helix.inputs = {
      nixpkgs.follows = "nixpkgs";
      rust-overlay.follows = "rust-overlay";
    };
    opencode.url = "github:anomalyco/opencode";
    opencode.inputs.nixpkgs.follows = "nixpkgs";
    wezterm.url = "github:wez/wezterm/main?dir=nix";
    wezterm.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "flake-utils";
      # NOTE WezTerm rust-overlay conflict (they did update it, but maybe it's a nixpkgs/nixos problem?)
      rust-overlay.follows = "rust-overlay";
    };
    yazi.url = "github:sxyazi/yazi";
    yazi.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "flake-utils";
      rust-overlay.follows = "rust-overlay";
    };
    zjstatus.url = "github:dj95/zjstatus";
    zjstatus.inputs = {
      nixpkgs.follows = "nixpkgs";
      # crane.follows = "crane";
      flake-utils.follows = "flake-utils";
      rust-overlay.follows = "rust-overlay";
    };
    zsh-helix-mode.url = "github:multirious/zsh-helix-mode";
    zsh-helix-mode.inputs.nixpkgs.follows = "nixpkgs";
    nix-doom-emacs-unstraightened.url = "github:marienz/nix-doom-emacs-unstraightened";
    nix-doom-emacs-unstraightened.inputs.nixpkgs.follows = "nixpkgs";

    # Modules
    mac-app-util.url = "github:hraban/mac-app-util";
    mynur.url = "github:schradert/nur";
    mynur.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-parts.follows = "flake-parts";
      # systems.follows = "systems";
      # gradle2nix.follows = "gradle2nix";
      # fenix.follows = "fenix";
    };
    nix-index.url = "github:nix-community/nix-index";
    nix-index.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-compat.follows = "flake-compat";
    };
    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";
    stylix.url = "github:nix-community/stylix";
    stylix.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-parts.follows = "flake-parts";
      # nur.follows = "nur";
    };

    # Overrides
    flake-compat.url = "github:edolstra/flake-compat";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # AI / Agents
    agency-agents.url = "github:msitarzewski/agency-agents";
    agency-agents.flake = false;
    datadog-agent-skills.url = "github:datadog-labs/agent-skills";
    datadog-agent-skills.flake = false;
    datadog-api-claude-plugin.url = "github:DataDog/datadog-api-claude-plugin";
    datadog-api-claude-plugin.flake = false;
    gastown.url = "github:steveyegge/gastown";
    gastown.flake = false;
  };
  outputs = inputs:
    inputs.canivete.lib.mkFlake {
      inherit inputs;
      everything = [./options ./modules ./pulumi];
    } {
      imports = [./nixidy ./modules/images.nix];

      # Hetzner Cloud golden image — minimal BIOS-bootable NixOS, standalone
      # from the canivete node machinery (see static/hetzner-image.nix).
      flake.nixosConfigurations.hetzner-image = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [./static/hetzner-image.nix];
      };

      canivete.meta = {
        domain = "trdos.me";
        root = "sirver";
        people.me = "tristan";
        people.users.tristan = {
          name = "Tristan Schrader";
          accounts.github = "schradert";
          profiles = {
            personal.email = "t0rdos@pm.me";
            personal.sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFBq/GWgq0+wAbRS53AqDdgXhyqpQtvcwlsPEguTPzL9 tristan@millionaire";
            work.email = "tristan@mill.com";
            work.sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICyH48Jn4iIN4o+0VfdQU+koUnHLhpS/V7B8M+2smi2k tristan@Tristans-MacBook-Pro.local";
          };
        };
      };
      canivete.nixidy.k8s = "rke2";
      canivete.pkgs.allowUnfree = ["displaylink" "oneplus-sdm845-firmware" "oneplus-sdm845-firmware-zstd"];
      canivete.sops.directory = "secrets/sops";
      canivete.deploy.nodes = {
        millionaire = {
          canivete.os = "macos";
          profiles.system.canivete.configuration = {
            imports = [./static/darwin-workstation.nix];
            profile = "work";
            system.stateVersion = 6;
            home-manager.sharedModules = [{home.stateVersion = "25.11";}];
            # FIXME no room for this
            # nix.linux-builder.enable = true;
            # Personal attic cache is NOT set system-wide on the dev host.
            # It's activated per-project via devenv's nix.settings to avoid
            # caching work builds on the personal cache.
            # Nodes (k8s-node.nix) have it system-wide since they're personal-only.
          };
        };
        # Personal Mac (./static/morgenmuffel.nix).
        morgenmuffel = {
          canivete.os = "macos";
          profiles.system.canivete.configuration.imports = [./static/morgenmuffel.nix];
        };
        # aarch64 VM on morgenmuffel, an RKE2 agent (./static/muffin.nix, run by ./static/muffin-vm.nix).
        # Restarted by darwin-rebuild of the Mac; never deployed with deploy-rs.
        muffin = {
          canivete.system = "aarch64-linux";
          profiles.system.canivete.configuration.imports = [./static/muffin.nix];
        };
        # FIXME reactivate
        # piper = {
        #   canivete.system = "aarch64-linux";
        #   profiles.system = {config, ...}: {
        #     canivete = {
        #       args = inputs;
        #       builder = modules:
        #         inputs.nixos-raspberrypi.lib.nixosInstaller {
        #           specialArgs = config.canivete.args;
        #           modules = [modules];
        #         };
        #       configuration = {
        #         imports = [./static/rpi.nix ./static/k8s-node.nix ./static/server.nix];
        #         system.stateVersion = "26.05";
        #         home-manager.sharedModules = [{home.stateVersion = "26.05";}];
        #         disko.devices.disk.root.device = "/dev/mmcblk0";
        #       };
        #     };
        #   };
        # };
        sirver = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            imports = [./static/facter ./static/k8s-node.nix ./static/server.nix];
            boot.initrd.availableKernelModules = ["sr_mod"];
            disko.devices.disk.root.device = "/dev/disk/by-id/scsi-35000c50067faa64b";
            # Mini switch on spare LAN to connect another system (dingo)
            networking.bridges.br0.interfaces = ["eno3" "eno4"];
            networking.interfaces.br0.useDHCP = true;
          };
        };
        octopus = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            imports = [./static/facter ./static/k8s-node.nix ./static/server.nix];
            boot.initrd.availableKernelModules = ["sr_mod"];
            disko.devices.disk.root.device = "/dev/disk/by-id/scsi-36b82a720cf60ce002fd94d2e2991b17e";
            services.rke2.role = "server";
          };
        };
        dingo = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            imports = [./static/facter ./static/k8s-node.nix ./static/server.nix];
            disko.devices.disk.root.device = "/dev/disk/by-id/ata-LITEON_IT_LCS-256L9S_SD0E97900L2TH61100DL";
            services.rke2.role = "server";
          };
        };

        # Agents
        bonobo = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            config,
            flake,
            lib,
            ...
          }: let
            inherit (flake.config.canivete.meta.people) me;
            user = config.users.users.${me};
            # Key names in a sops file are cleartext. sops-nix fails activation on a missing key, so
            # this is off until pulumi (android_adb_key_sops_write) has written the key and the file is committed.
            adbKeyWritten = lib.hasInfix "\nandroid:\n    adb-key:" (builtins.readFile ./secrets/sops/default.yaml);
          in {
            imports = [./static/facter ./static/k8s-node.nix ./static/server.nix];
            disko.devices.disk.root.device = "/dev/disk/by-id/ata-Micron_1100_SATA_256GB_165015496CBD";
            # Host-level TCP relay fronting the internal Cilium gateway on bonobo's
            # tailnet IP (external-dns-internal points *.trdos.me here). See tailnet.nix.
            tailnet.gatewayRelay = "100.64.0.4";
            # Own containerd unit, so rke2 restarts keep pods running (docs/node-standard.md, "Next node roll").
            externalContainerd.enable = true;
            nodeRemediation.eligible = true;
            # The adb key `android <device>` connects with (pulumi android_adb_key, docs/android-fleet.md)
            sops.secrets = lib.mkIf adbKeyWritten {
              android-adb-key = {
                key = "android/adb-key";
                path = "${user.home}/.android/adbkey";
                owner = me;
                mode = "0600";
              };
            };
            # sops-install-secrets creates missing parents as root; make it the user's first
            system.activationScripts = lib.mkIf adbKeyWritten {
              androidAdbDir = {
                deps = ["users" "groups"];
                text = "[ ! -d ${user.home} ] || install -d -o ${me} -g ${user.group} -m 0700 ${user.home}/.android";
              };
              setupSecrets.deps = ["androidAdbDir"];
            };
          };
        };
        chinchilla = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            imports = [./static/facter ./static/k8s-node.nix ./static/server.nix ./static/attic-server.nix];
            disko.devices.disk.root.device = "/dev/disk/by-id/ata-MTFDDAK256TBN-1AR1ZABHA_UGXVK01J7BDCER";
            # Second gateway relay (round-robin with bonobo) on chinchilla's
            # tailnet IP; external-dns-internal lists both A records. See tailnet.nix.
            tailnet.gatewayRelay = "100.64.0.5";
            externalContainerd.enable = true;
            nodeRemediation.eligible = true;
          };
        };

        # x86_64-linux desktop that also hosts all the USB-connected microcontrollers.
        # `system` is its NixOS config (./static/falcon-system.nix); every other
        # profile flashes one physical board (see ./static/falcon.nix).
        # `deploy '.#falcon.system'` switches NixOS; `deploy '.#falcon.<board>'`
        # flashes one board; bare `.#falcon` does both. Disconnected boards print
        # a "skipping" line and exit 0.
        falcon = inputs.nixpkgs.lib.mkMerge [
          (import ./static/falcon.nix)
          {profiles.system.canivete.configuration.imports = [./static/facter ./static/falcon-system.nix];}
        ];
        # Dell Precision 7510 laptop on DisplayLink docks (./static/axolotl.nix).
        axolotl = {
          hostname = "192.168.50.250";
          sshUser = "tristan";
          sshOpts = ["-J" "tristan@192.184.168.248"];
          remoteBuild = true;
          profiles.system.canivete.configuration.imports = [./static/axolotl.nix];
        };
        # Steam Deck OLED on Jovian (./static/systeamadeck.nix).
        systeamadeck = {
          hostname = "192.168.50.155";
          sshUser = "tristan";
          sshOpts = ["-J" "tristan@192.184.168.248"];
          remoteBuild = true;
          profiles.system.canivete.configuration.imports = [./static/systeamadeck.nix];
        };
        # OnePlus 6 on mobile-nixos (./static/gargoyle.nix).
        gargoyle = {
          hostname = "192.168.50.192";
          sshUser = "tristan";
          sshOpts = ["-J" "tristan@192.184.168.248"];
          canivete.system = "aarch64-linux";
          profiles.system.canivete.configuration.imports = [./static/gargoyle.nix];
        };
        # NixOS-WSL (./static/echidna.nix).
        echidna.profiles.system.canivete.configuration.imports = [./static/echidna.nix];
        # Cloud-burst worker image config — never deployed via pulumi or
        # deploy-rs; defined as a node only so it gets the canivete.kubernetes
        # module machinery. CAPI boots Hetzner VMs from its uploaded snapshot
        # (static/cloud-worker.nix; upload command lives in pulumi).
        cloud-worker.profiles.system.canivete.configuration = {
          imports = [./static/cloud-worker.nix];
        };

        # Hetzner cx33 VPS — headscale + AdGuard Home outside the cluster.
        # SSH hostname is overridden at deploy time via --hostname (the IP from
        # pulumi); networking.hostName stays "hyena".
        hyena = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            imports = [./static/hyena.nix];
            disko.devices.disk.root.device = "/dev/sda";
            # No node advertises pod routes any more (docs/tailscale-integration.md, "Pod routes"): stop auto-approving 10.0.0.0/8.
            tailnet.podRoutes = false;
          };
        };

        voron = {
          canivete.system = "aarch64-linux";
          profiles.system = {config, ...}: {
            canivete = {
              args = inputs;
              builder = modules:
                inputs.nixos-raspberrypi.lib.nixosSystem {
                  inherit (inputs) nixpkgs;
                  specialArgs = config.canivete.args;
                  modules = [modules];
                };
              configuration = {
                imports = [./static/rpi.nix ./static/printer.nix];
                system.stateVersion = "26.05";
                home-manager.sharedModules = [{home.stateVersion = "26.05";}];
                disko.devices.disk.root.device = "/dev/mmcblk0";
                networking.hostName = "voron";
              };
            };
          };
        };
      };
    };
}
