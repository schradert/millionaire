# Unported: nix-alien (old/modules/nixos/fhs.nix; needs flake input).
{
  nixos = {
    config,
    lib,
    ...
  }: {
    # Run unpatched binaries (nix-ld) and resolve /bin, /usr/bin shebangs (envfs)
    config = lib.mkIf config.profiles.client.enable {
      programs.nix-ld.enable = true;
      services.envfs.enable = true;
    };
  };
}
