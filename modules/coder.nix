# Coder workspaces from workstations (docs/dev-workspaces.md): the CLI and the
# SSH block `coder config-ssh` would write, so `ssh coder.<workspace>` and
# `zed ssh://coder.<workspace>/home/coder/<repo>` work after one
# `coder login https://coder.<domain>`. Work Macs reach headscale only through
# the userspace tailscaled's proxy (modules/tailnet.nix), hence `trdos`.
{
  # nixpkgs' coder wraps terraform (BSL) for its provisioners
  canivete.pkgs.allowUnfree = ["terraform"];
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    coder = lib.getExe pkgs.coder;
    proxy = lib.optionalString (config.profile == "work") "trdos ";
  in {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = [pkgs.coder];
      programs.ssh.matchBlocks."coder.*" = {
        proxyCommand = "${proxy}${coder} ssh --stdio --ssh-host-prefix coder. %h";
        user = "coder";
        extraOptions = {
          ConnectTimeout = "0";
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
          LogLevel = "ERROR";
        };
      };
    };
  };
}
