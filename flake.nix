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
    deploy-rs.inputs = {
      flake-compat.follows = "flake-compat";
      nixpkgs.follows = "nixpkgs";
      utils.follows = "flake-utils";
    };
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
    nixhelm = {
      url = "github:nix-community/nixhelm";
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
    datadog-agent-skills.url = "github:datadog-labs/agent-skills";
    datadog-agent-skills.flake = false;
    datadog-api-claude-plugin.url = "github:DataDog/datadog-api-claude-plugin";
    datadog-api-claude-plugin.flake = false;
    datadog-pup.url = "github:datadog-labs/pup";
    datadog-pup.flake = false;

    # Special
    kdl.url = "https://raw.githubusercontent.com/jrobsonchase/nixos-config/8ea380ad196e630044846f06945131602ec7056f/lib/kdl.nix";
    kdl.flake = false;
  };
  outputs = inputs:
    inputs.canivete.lib.mkFlake {
      inherit inputs;
      everything = [./options ./modules ./pulumi ./esp32-s3];
    } {
      imports = [./nixidy ./modules/images.nix];
      devenv = {lib, ...}: {
        git-hooks.hooks = {
          lychee.toml.accept = [200 403 405 406];
          no-commit-to-branch.enable = lib.mkForce false;
        };
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
      canivete.sops.directory = "secrets/sops";
      canivete.deploy.nodes = {
        millionaire = {
          canivete.os = "macos";
          profiles.system.canivete.configuration = {
            flake,
            lib,
            ...
          }: {
            imports = with flake.inputs.srvos.darwinModules; [desktop mixins-terminfo];
            profile = "work";
            profiles.workstation.enable = true;
            system.stateVersion = 6;
            home-manager.sharedModules = [{home.stateVersion = "25.11";}];
            nix.linux-builder.enable = true;
            # Personal attic cache is NOT set system-wide on the dev host.
            # It's activated per-project via devenv's nix.settings to avoid
            # caching work builds on the personal cache.
            # Nodes (server.nix) have it system-wide since they're personal-only.
            nix.buildMachines = let
              mkBuilder = hostName: {
                inherit hostName;
                systems = ["x86_64-linux"];
                sshUser = "nix-remote-builder";
                sshKey = "/Users/tristan/.ssh/personal";
                protocol = "ssh-ng";
                supportedFeatures = ["kvm" "benchmark" "big-parallel"];
                maxJobs = 4;
              };
            in
              map mkBuilder ["sirver" "octopus" "dingo" "bonobo" "chinchilla"];
            nix.settings.trusted-users = ["@admin"];

            # TODO follow broken Nix 2.33 with Devenv 1.11.2 support
            # NOTE https://github.com/cachix/devenv/issues/2364
            nix.settings.experimental-features = lib.mkForce [
              "nix-command"
              "flakes"
              "fetch-closure"
              "recursive-nix"
              "configurable-impure-env"
              # "ca-derivations"
              "impure-derivations"
              "blake3-hashes"
            ];
          };
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
        #         imports = [./static/rpi.nix ./static/server.nix];
        #         system.stateVersion = "26.05";
        #         home-manager.sharedModules = [{home.stateVersion = "26.05";}];
        #         disko.devices.disk.root.device = "/dev/mmcblk0";
        #       };
        #     };
        #   };
        # };
        sirver = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {config, ...}: {
            imports = [./static/facter ./static/server.nix];
            boot.initrd.availableKernelModules = ["sr_mod"];
            disko.devices.disk.root.device = "/dev/disk/by-id/scsi-35000c50067faa64b";
            # Mini switch on spare LAN to connect another system (dingo)
            networking.bridges.br0.interfaces = ["eno3" "eno4"];
            networking.interfaces.br0.useDHCP = true;

            # Attic binary cache server
            services.atticd = {
              enable = true;
              environmentFile = config.sops.secrets.attic-server-key.path;
              settings.listen = "[::]:8199";
            };
            sops.secrets.attic-server-key.key = "attic/server-key";
            networking.firewall.allowedTCPPorts = [8199];
          };
        };
        octopus = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            imports = [./static/facter ./static/server.nix];
            boot.initrd.availableKernelModules = ["sr_mod"];
            disko.devices.disk.root.device = "/dev/disk/by-id/scsi-36b82a720cf60ce002fd94d2e2991b17e";
            services.rke2.role = "server";
          };
        };
        dingo = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            imports = [./static/facter ./static/server.nix];
            disko.devices.disk.root.device = "/dev/disk/by-id/ata-LITEON_IT_LCS-256L9S_SD0E97900L2TH61100DL";
            services.rke2.role = "server";
          };
        };

        # Agents
        bonobo = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            imports = [./static/facter ./static/server.nix];
            disko.devices.disk.root.device = "/dev/disk/by-id/ata-Micron_1100_SATA_256GB_165015496CBD";
          };
        };
        chinchilla = {
          remoteBuild = true;
          profiles.system.canivete.configuration = {
            imports = [./static/facter ./static/server.nix];
            disko.devices.disk.root.device = "/dev/disk/by-id/ata-MTFDDAK256TBN-1AR1ZABHA_UGXVK01J7BDCER";
          };
        };
      };
    };
}
