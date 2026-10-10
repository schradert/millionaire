# RuneScape clients as Steam shortcuts: RSC+ (Classic), RuneLite and HDOS
# (Old School). The official runescape-launcher is gone from the internet.
# Unported: the 2009scape Saradomin launcher (its NuGet build fails; kept in
# old/old/apps/gaming/games/runescape/).
{
  home = {
    can,
    config,
    lib,
    pinned,
    pkgs,
    ...
  }: let
    cfg = config.programs.steam.external.runescape;
    # RSC+ keeps its data and cache next to its executable
    rscplusPath = ".config/RSCPlus/rscplus";
  in {
    options.programs.steam.external.runescape = {
      rscplus.enable = can.enable "RSC+ (OpenRSC client)" {};
      rscplus.package = can.package "rscplus" {default = pinned.rscplus;};
      runelite.enable = can.enable "RuneLite (Old School client)" {};
      runelite.package = can.package "runelite" {default = pkgs.runelite;};
      hdos.enable = can.enable "HDOS (high-definition Old School client)" {};
      hdos.package = can.package "hdos" {default = pinned.hdos;};
    };
    config = lib.mkMerge [
      (lib.mkIf cfg.rscplus.enable {
        home.file.${rscplusPath}.source = cfg.rscplus.package;
        programs.steam.external.manual."RSC+".shortcut.exe = "${config.home.homeDirectory}/${rscplusPath}/bin/rscplus";
      })
      # TODO RuneLite does not exit cleanly from Steam
      (lib.mkIf cfg.runelite.enable {programs.steam.external.manual.RuneLite.shortcut.exe = lib.getExe cfg.runelite.package;})
      (lib.mkIf cfg.hdos.enable {programs.steam.external.manual.HDOS.shortcut.exe = lib.getExe cfg.hdos.package;})
    ];
  };
}
