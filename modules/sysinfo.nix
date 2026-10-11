# System/repo summaries. Unported: inxi, cpufetch, macchina (old/old/hardware/default.nix).
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = [pkgs.onefetch];
      programs.fastfetch.enable = true;
    };
  };
}
