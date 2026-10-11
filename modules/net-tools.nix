# Network CLIs: port scanning, speed tests, file transfer, cloud storage.
# rclone web GUI runs on the cluster: nixidy/apps/home/rclone.nix.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs; [croc librespeed-cli nmap rustscan termscp];
      programs.rclone.enable = true;
    };
  };
}
