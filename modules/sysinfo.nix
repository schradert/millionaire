# System/repo summaries.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs; [inxi macchina onefetch];
      programs.fastfetch.enable = true;
    };
  };
}
