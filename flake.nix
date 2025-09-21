{
  description = "";
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    mac-app-util.url = "github:hraban/mac-app-util";

    wezterm.url = "github:wez/wezterm/main?dir=nix";
    wezterm.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "flake-utils";
      # NOTE WezTerm rust-overlay conflict (they did update it, but maybe it's a nixpkgs/nixos problem?)
      rust-overlay.follows = "rust-overlay";
    };
    zjstatus.url = "github:dj95/zjstatus";
    zjstatus.inputs = {
      nixpkgs.follows = "nixpkgs";
      # crane.follows = "crane";
      flake-utils.follows = "flake-utils";
      rust-overlay.follows = "rust-overlay";
    };
    yazi.url = "github:sxyazi/yazi";
    yazi.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "flake-utils";
      rust-overlay.follows = "rust-overlay";
    };
    mynur.url = "github:schradert/nur";
    mynur.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-parts.follows = "flake-parts";
      # systems.follows = "systems";
      # gradle2nix.follows = "gradle2nix";
      # fenix.follows = "fenix";
    };
    stylix.url = "github:nix-community/stylix";
    stylix.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-parts.follows = "flake-parts";
      # nur.follows = "nur";
    };
    nix-index.url = "github:nix-community/nix-index";
    nix-index.inputs.nixpkgs.follows = "nixpkgs";
    # nix-index.inputs.flake-compat.follows = "flake-compat";
    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    # Overrides
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = inputs: inputs.flake-parts.lib.mkFlake {inherit inputs;} {
    systems = ["aarch64-darwin"];
    flake.darwinConfigurations.millionaire = inputs.nix-darwin.lib.darwinSystem {
      modules = [
        ({config, lib, ...}: {
          options.my.nixpkgs.config.allowUnfreePackages = lib.mkOption {
            type = with lib.types; listOf str;
            default = [];
          };
          config.nixpkgs.config.allowUnfreePredicate = pkg: lib.elem (lib.getName pkg) config.my.nixpkgs.config.allowUnfreePackages;
        })
        ({lib, pkgs, ...}: {
          imports = [
            inputs.home-manager.darwinModules.default
            inputs.mac-app-util.darwinModules.default
            inputs.stylix.darwinModules.stylix
          ];
          my.nixpkgs.config.allowUnfreePackages = ["slack" "claude-code"];
          system.stateVersion = 6;
          nixpkgs.hostPlatform = "aarch64-darwin";
          system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;
          nix.settings.experimental-features = "nix-command flakes";
          nixpkgs.overlays = [
            inputs.mynur.overlays.zellij
            inputs.mynur.overlays.zellij-plugins
            inputs.mynur.inputs.fenix.overlays.default
            inputs.nix-index-database.overlays.nix-index
          ];
          networking.hostName = "millionaire";
          time.timeZone = "America/Los_Angeles";
          users.users.tristan.home = "/Users/tristan";
          users.users.tristan.openssh.authorizedKeys.keyFiles = [./me.pub];
          stylix.enable = true;
          stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/dracula.yaml";
          security.pam.services.sudo_local.touchIdAuth = true;
          security.sudo.extraConfig = ''
            root ALL=(ALL) NOPASSWD: ALL
            %admin ALL=(ALL) NOPASSWD: ALL
          '';
          services.tailscale.enable = true;
          system.primaryUser = "tristan";
          system.defaults.dock = {
            autohide = true;
            orientation = "left";
            static-only = true;
          };
          homebrew.enable = true;
          homebrew.casks = ["docker-desktop" "snowflake-snowsql"];
          home-manager.extraSpecialArgs = {inherit inputs;};
          home-manager.useGlobalPkgs = true;
          home-manager.users.tristan = {
            imports = [
              inputs.mac-app-util.homeManagerModules.default
              inputs.mynur.homeManagerModules.zellij-plugins
              inputs.nix-index-database.homeModules.nix-index
              ./modules/zsh.nix
              ./modules/git.nix
              ./modules/granted.nix
              ./modules/zellij.nix
              ./modules/starship.nix
            ];
            home.stateVersion = "25.11";
            home.packages = with pkgs; [
              bitwarden
              brave
              slack

              bottom
              gping
              hwatch
              iftop
              lnav
              lsof
              procps
              trippy
              zenith

              nix-inspect
              nix-fast-build
              nix-output-monitor

              lazydocker

              (pulumi.withPackages (ps: with ps; [pulumi-python]))
            ];
            programs = {
              bat.enable = true;
              btop.enable = true;
              btop.settings.vim_keys = true;
              carapace.enable = true;
              claude-code.enable = true;
              dircolors.enable = true;
              direnv.enable = true;
              eza.enable = true;
              fd.enable = true;
              fzf.enable = true;
              go.enable = true;
              helix.enable = true;
              helix.settings.editor.file-picker.hidden = false;
              home-manager.enable = true;
              jq.enable = true;
              jqp.enable = true;
              navi.enable = true;
              nix-index.enable = true;
              nix-index.package = pkgs.nix-index-with-db;
              nix-index-database.comma.enable = true;
              rbw.enable = true;
              ripgrep.enable = true;
              spotify-player.enable = true;
              ssh.enable = true;
              ssh.enableDefaultConfig = false;
              vim.enable = true;
              wezterm.enable = true;
              yazi.enable = true;
              zoxide.enable = true;
            };
          };
        })
      ];
    }; 
  };
}
