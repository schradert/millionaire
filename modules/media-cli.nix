# Terminal media: yt-dlp (with youtube-dl alias), cava visualizer.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      programs.cava.enable = true;
      programs.yt-dlp.enable = true;
      programs.yt-dlp.package = pkgs.yt-dlp.override {withAlias = true;};
    };
  };
}
