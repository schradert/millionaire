{
  dotfiles.home-manager = {pkgs, ...}: {
    home.packages = with pkgs; [
      # Hacking
      metasploit
    ];
    # programs.sniffnet.enable = true;
  };
}
