# Terminal apps: numbat calculator, tldr pages, stock tickers, Hacker News.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs; [circumflex ticker tickrs];
      programs.numbat.enable = true;
      programs.tealdeer.enable = true;
    };
  };
}
