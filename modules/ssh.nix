# Client defaults. Unported from old/old/network/ssh.nix: sops-deployed private
# keys, per-node matchBlocks (static/builders.nix + tailnet cover node access),
# global ForwardAgent, opentofu github/gitlab key upload.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      programs.ssh.matchBlocks."*".addKeysToAgent = "yes";
      services.ssh-agent.enable = pkgs.stdenv.hostPlatform.isLinux;
    };
  };
}
