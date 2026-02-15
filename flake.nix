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
    devenv.url = "github:cachix/devenv";
    devenv-agents.url = "github:cachix/devenv-ai-agents";
    devenv-agents.flake = false;

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
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
    nixos-raspberrypi.inputs.nixpkgs.follows = "nixpkgs";
    # TODO submit feature upstream
    # nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.url = "github:schradert/nixos-anywhere";
    nixos-anywhere.inputs = {
      flake-parts.follows = "flake-parts";
      nixpkgs.follows = "nixpkgs";
      disko.follows = "disko";
      # treefmt-nix.follows = "treefmt";
    };
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Programs
    helix.url = "github:helix-editor/helix";
    helix.inputs = {
      nixpkgs.follows = "nixpkgs";
      rust-overlay.follows = "rust-overlay";
    };
    opencode.url = "github:sst/opencode";
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
    zed.url = "github:zed-industries/zed";
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
    # Needed for nixos-raspberrypi right now
    # TODO follow merge of https://github.com/NixOS/nixpkgs/pull/398456
    nixpkgs.url = "github:schradert/nixpkgs/nixos-unstable-398456";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = inputs:
    inputs.canivete.lib.mkFlake {
      inherit inputs;
      everything = [./options ./modules ./pulumi ./esp32-s3];
    } {
      perSystem.canivete.devenv.shells.default = {lib, ...}: {
        git-hooks.hooks.lychee.toml.accept = [200 403 405 406];
        git-hooks.hooks.no-commit-to-branch.enable = lib.mkForce false;
      };
      canivete.meta = {
        domain = "trdos.me";
        people.me = "tristan";
        people.users.tristan = {
          name = "Tristan Schrader";
          accounts.github = "schradert";
          profiles = {
            personal.email = "t0rdos@pm.me";
            work.email = "tristan@mill.com";
            work.sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICyH48Jn4iIN4o+0VfdQU+koUnHLhpS/V7B8M+2smi2k tristan@Tristans-MacBook-Pro.local";
          };
        };
      };
      canivete.deploy.nodes = {
        millionaire = {
          canivete.os = "macos";
          profiles.system.canivete.configuration = {
            profile = "work";
            profiles.workstation.enable = true;
            system.stateVersion = 6;
            home-manager.sharedModules = [{home.stateVersion = "25.11";}];
            nix.linux-builder.enable = true;
            nix.settings.trusted-users = ["@admin"];
          };
        };
        piper = {
          canivete.system = "aarch64-linux";
          profiles.system = {config, ...}: {
            canivete = {
              args = inputs;
              builder = modules:
                inputs.nixos-raspberrypi.lib.nixosInstaller {
                  specialArgs = config.canivete.args;
                  modules = [modules];
                };
              configuration = {
                imports = [./static/rpi.nix];
                system.stateVersion = "26.05";
                home-manager.sharedModules = [{home.stateVersion = "26.05";}];
                networking.hostId = "919e7a2c";
                disko.devices.disk.root.device = "/dev/mmcblk0";
              };
            };
          };
        };
      };
    };
}
