# RuneScape clients as Steam shortcuts: RSC+ (Classic), RuneLite and HDOS
# (Old School), Saradomin (2009scape). The official runescape-launcher is gone
# from the internet.
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
      saradomin.enable = can.enable "Saradomin (2009scape launcher)" {};
      saradomin.package = can.package "saradomin" {default = pinned.saradomin;};
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
      (lib.mkIf cfg.saradomin.enable {programs.steam.external.manual.Saradomin.shortcut.exe = lib.getExe cfg.saradomin.package;})
      (lib.mkIf cfg.hdos.enable {programs.steam.external.manual.HDOS.shortcut.exe = lib.getExe cfg.hdos.package;})
    ];
  };
}
