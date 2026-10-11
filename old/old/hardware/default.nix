{
  dotfiles.home-manager = {
    lib,
    pkgs,
    ...
  }: {
    home.packages = with pkgs; [
      inxi
      cpufetch
    ];
    programs.macchina.enable = true;
    programs.macchina.settings = {
      interface = lib.mkDefault "en0";
      theme = "Dracula";
    };
  };
}
