# `profiles.gaming`: Steam with Proton and launchers (NixOS), and games (home).
{
  canivete.pkgs.allowUnfree = [
    "steam"
    "steam-unwrapped"
    "steam-run"
    "steam-original"
    # Jovian (Steam Deck)
    "steam-jupiter-original"
    "steam-jupiter-unwrapped"
    "steamcmd"
    "steamdeck-hw-theme"
  ];
  system = {flake, ...}: {nixpkgs.overlays = [flake.inputs.mynur.overlays.tetrigo];};
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.gaming.enable {
      assertions = lib.toList {
        assertion = config.profiles.client.enable;
        message = "profiles.gaming needs profiles.client";
      };
      programs.steam = {
        enable = true;
        extraCompatPackages = with pkgs; [proton-ge-bin steamtinkerlaunch steam-play-none];
        protontricks.enable = true;
      };
      programs.gamemode = {
        enable = true;
        enableRenice = true;
      };
    };
  };
  home = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: {
    imports = [flake.inputs.mynur.homeManagerModules.tetrigo];
    config = lib.mkIf config.profiles.gaming.enable {
      programs.tetrigo.enable = true;
      home.packages = with pkgs;
        [
          # roguelikes
          boohu
          brogue-ce
          brutalmaze
          # GCC 16 makes -Wsfinae-incomplete an error (stable 0.I too)
          (cataclysm-dda-git.overrideAttrs (o: {
            env = (o.env or {}) // {NIX_CFLAGS_COMPILE = toString (o.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error=sfinae-incomplete";};
          }))
          chess-tui
          crawl
          crawlTiles
          dopewars
          harmonist
          hyperrogue
          minesweep-rs
          moon-buggy
          narsil
          nethack
          rogue
          the-legend-of-edgar
          tty-solitaire
          # pixel dungeons
          shattered-pixel-dungeon
          experienced-pixel-dungeon
          summoning-pixel-dungeon
          rat-king-adventure
          # typing
          ngrrram
          smassh
          thokr
        ]
        ++ lib.optionals stdenv.hostPlatform.isLinux [
          _4d-minesweeper
          arx-libertatis
          bastet
          flitter
          galaxis
          haskellPackages.Allure
          heroic
          infra-arcana
          ivan
          # keeperrl: fails to compile in nixpkgs (2026-05)
          pokete
          sil
          sil-q
          steam-tui
          xbomb
          zeroad
        ];
    };
  };
}
