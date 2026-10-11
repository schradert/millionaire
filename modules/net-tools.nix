# Network CLIs: port scanning, speed tests, cloud storage.
# Unported: rclone rcd web-GUI cluster app + croc/termscp (old/old/storage/rclone.nix).
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs; [librespeed-cli nmap rustscan];
      programs.rclone.enable = true;
    };
  };
}
