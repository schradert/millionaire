# Emulated consoles: ROMs/BIOS by title from the game library
# (pinned.{roms,bios}, docs/games.md), RetroArch cores or standalone
# emulators per console, and SRM parsers for each.
# Partial: the library on games.trdos.me is not populated yet; the old
# myrient hash table (incl. the unhashed wishlist) stays in
# old/old/apps/gaming/games/roms.nix until docs/games.md is done.
{
  canivete.pkgs.allowUnfree = ["rpcs3"];
  home = {
    can,
    config,
    lib,
    pinned,
    pkgs,
    ...
  }: let
    inherit (lib) mkDefault mkOption types;
    cfg = config.programs.steam.external;
    ini = pkgs.formats.ini {};
    rom = "\${romsdirglobal}\${/}";
    retroarch = core: preset: dir: {
      retroarch = mkDefault true;
      wrapper = mkDefault core;
      parsers.${preset}.overrides.romDirectory = mkDefault "${rom}${dir}";
    };
    standalone = pkg: preset: dir: {
      wrapper = mkDefault pkg;
      parsers.${preset}.overrides = {
        romDirectory = mkDefault "${rom}${dir}";
        executable.path = mkDefault (lib.getExe pkg);
      };
    };
  in {
    options.programs.steam.external = {
      library = can.enable "fetch titles, BIOS and installers from games.trdos.me (until it is populated, see docs/games.md, they are left out)" {};
      retroarch.package = can.package "RetroArch with the consoles' cores" {default = pkgs.retroarch;};
      retroarch.settings = mkOption {
        inherit (ini) type;
        default = {};
        description = "retroarch.cfg (not installed yet: RetroArch rewrites it)";
      };
      consoles = mkOption {
        type = types.attrsOf (types.submodule ({
          config,
          name,
          ...
        }: {
          options = {
            retroarch = can.enable "run through a RetroArch core (wrapper is the core)" {};
            wrapper = mkOption {
              type = types.nullOr types.package;
              default = null;
              description = "Emulator, or libretro core when `retroarch`";
            };
            titles = can.list.str "ROMs by name, from pinned.roms.\"<console>/<title>\"" {default = [];};
            biosNames = can.list.str "BIOS by name, from pinned.bios.\"<console>/<name>\"" {default = [];};
          };
          config = lib.mkIf cfg.library {
            programs = map (t: pinned.roms."${name}/${t}") config.titles;
            bios = map (b: pinned.bios."${name}/${b}") config.biosNames;
          };
        }));
      };
    };
    config = lib.mkIf cfg.enable {
      programs.steam.external = {
        manual = lib.mapAttrs (_: exe: {shortcut.exe = exe;}) {
          RetroArch = lib.getExe cfg.retroarch.package;
          Cemu = lib.getExe pkgs.cemu;
          RPCS3 = lib.getExe cfg.consoles.PS3.wrapper;
          Xemu = lib.getExe pkgs.xemu;
        };
        retroarch.package =
          pkgs.retroarch.withCores (_:
            lib.mapAttrsToList (_: c: c.wrapper) (lib.filterAttrs (_: c: c.retroarch && c.wrapper != null) cfg.consoles));
        # TODO RetroAchievements password from a secret
        retroarch.settings.global = {
          input_joypad_driver = "sdl2";
          rewind_enable = true;
          input_rewind_btn = 19;
          input_toggle_fast_forward_btn = 18;
          cheevos_enable = true;
          cheevos_username = "retoro";
          cheevos_unlock_sound_enable = true;
          cheevos_auto_screenshot = true;
          cheevos_badges_enable = true;
          cheevos_start_active = true;
        };
        srm.settings.environmentVariables = {
          retroarchPath = lib.getExe cfg.retroarch.package;
          raCoresDirectory = "${cfg.retroarch.package}/lib/retroarch/cores";
        };
        consoles = with pkgs; {
          NES = retroarch libretro.fceumm "Nintendo NES - Retroarch - FCEUmm" "NES";
          SNES = lib.recursiveUpdate (retroarch libretro.bsnes-hd "Nintendo SNES - Retroarch - bsnes-hd" "SNES") {
            parsers."Nintendo SNES - Retroarch - bsnes-hd" = {
              preset = mkDefault "Nintendo SNES - Retroarch - Beetle bsnes";
              overrides.executableArgs = mkDefault "-L \${os:win|cores|\${os:mac|\${racores}|\${os:linux|\${racores}}}}\${/}bsnes_hd_beta_libretro.\${os:win|dll|\${os:mac|dylib|\${os:linux|so}}} \\\"\${filePath}\\\"";
            };
          };
          GB = retroarch libretro.sameboy "Nintendo Game Boy - Retroarch - SameBoy" "GB";
          GBC = retroarch libretro.sameboy "Nintendo Game Boy Color - Retroarch - SameBoy" "GBC";
          GBA = retroarch libretro.mgba "Nintendo Game Boy Advance - Retroarch - mGBA" "GBA";
          N64 = retroarch libretro.mupen64plus "Nintendo 64 - Retroarch - Mupen64Plus Next" "N64";
          GC = retroarch libretro.dolphin "Nintendo GameCube - Retroarch - Dolphin" "GC";
          Wii = retroarch libretro.dolphin "Nintendo Wii - Retroarch - Dolphin" "Wii";
          DS = retroarch libretro.melonds "Nintendo DS - Retroarch - melonDS" "DS";
          "3DS" = retroarch libretro.citra "Nintendo 3DS - Retroarch - Citra" "3DS";
          WiiU = standalone cemu "Nintendo Wii U - Cemu (Image)" "WiiU";
          # DuckStation left nixpkgs (upstream request)
          PS1 = retroarch libretro.swanstation "Sony PlayStation - Retroarch - SwanStation" "PS1";
          PS2 = retroarch libretro.pcsx2 "Sony PlayStation 2 - Retroarch - PCSX2" "PS2";
          # CUDA hosts (cudaSupport) would otherwise rebuild opencv with unfree CUDA libs
          PS3 = standalone (rpcs3.override {opencv = opencv.override {enableCuda = false;};}) "Sony PlayStation 3 - RPCS3 (Extracted ISO)" "PS3";
          PSP = retroarch libretro.ppsspp "Sony PlayStation Portable - Retroarch - PPSSPP" "PSP";
          XB = standalone xemu "Microsoft Xbox - Xemu" "XB";
        };
      };
      home.packages =
        [cfg.retroarch.package]
        ++ lib.mapAttrsToList (_: c: c.wrapper) (lib.filterAttrs (_: c: !c.retroarch && c.wrapper != null) cfg.consoles);
      home.file.".local/share/Cemu/keys.txt" = lib.mkIf (cfg.library && cfg.consoles.WiiU.titles != []) {source = pinned.cemu-keys;};
    };
  };
}
