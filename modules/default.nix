{
  canivete.pkgs.allowUnfree = ["beeper" "discord" "slack" "spotify"];
  system = {
    flake,
    lib,
    ...
  }: {
    nix.settings.trusted-users = ["root"];
    nixpkgs.config.allowUnfreePredicate = pkg: lib.elem (lib.getName pkg) flake.config.canivete.pkgs.allowUnfree;
    time.timeZone = "America/Los_Angeles";
    home-manager.useGlobalPkgs = true;
  };
  darwin = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      homebrew.casks = ["beeper"];
    };
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable (lib.mkMerge [
      {
        home.packages = with pkgs; [
          bottom
          gping
          hwatch
          iftop
          lnav
          lsof
          procps
          trippy
          zenith
        ];
        programs = {
          bat.enable = true;
          btop.enable = true;
          btop.settings.vim_keys = true;
          carapace.enable = true;
          dircolors.enable = true;
          elvish.initExtra = "eval (${lib.getExe config.programs.carapace.package} _carapace elvish | slurp)";
          eza = {
            enable = true;
            git = true;
            icons = "auto";
            extraOptions = ["--color=always" "--group-directories-first"];
          };
          fd.enable = true;
          fzf.enable = true;
          home-manager.enable = true;
          jq.enable = true;
          jqp.enable = true;
          ripgrep.enable = true;
          ssh.enable = true;
          ssh.enableDefaultConfig = false;
          zoxide.enable = true;
        };
      }
      (lib.mkIf config.profiles.workstation.enable {
        home.packages = with pkgs;
          lib.mkMerge [
            [
              bitwarden-desktop
              brave
              discord
              (spotify.overrideAttrs (_: {
                src = pkgs.fetchurl {
                  url = "https://web.archive.org/web/20250912003756/https://download.scdn.co/SpotifyARM64.dmg";
                  hash = "sha256-fTyACxbyIgg7EwIgnNvNerJGUwAVLP2bg0TMnOegWeQ=";
                };
              }))
            ]
            (lib.mkIf stdenv.hostPlatform.isLinux [beeper])
          ];
        programs = {
          elvish.enable = true;
          navi.enable = true;
          rbw.enable = true;
          spotify-player.enable = true;
          wezterm.enable = true;
          # FIXME why do I keep having to rebuild this?!
          # zed-editor.enable = true;
        };
      })
    ]);
  };
}
