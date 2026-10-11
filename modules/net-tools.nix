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
      # termscp on darwin: nixpkgs samba dylibs keep build-dir install names (dyld abort)
      home.packages = with pkgs; [croc librespeed-cli nmap rustscan] ++ lib.optional stdenv.hostPlatform.isLinux termscp;
      programs.rclone.enable = true;
    };
  };
}
