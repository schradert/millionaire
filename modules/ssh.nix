# Client defaults. Private keys are sops-provisioned: modules/workstation-keys.nix.
{
  # Pinned host keys for the deploy jump host (flake.nix sshOpts) and axolotl, so
  # `deploy` never prompts. Cluster nodes and falcon: static/builder.nix; Macs: modules/builders.nix.
  nixos = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      programs.ssh.knownHosts =
        lib.mapAttrs' (n: p:
          lib.nameValuePair "lan-${n}" {
            hostNames = [n p.lan];
            publicKey = p.hostKey;
          })
        (import ../static/builders.nix).nodes
        // {
          # a port-forward to sirver, so it presents sirver's key (as in modules/builders.nix)
          edge = {
            hostNames = ["192.184.168.248"];
            publicKey = (import ../static/builders.nix).nodes.sirver.hostKey;
          };
          axolotl = {
            hostNames = ["axolotl" (import ../static/builders.nix).axolotl.lan];
            publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAOwwGlApwAVdNrflHHk/DkxDapP7RevXV8jjnOrjqfD";
          };
        };
    };
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      programs.ssh.matchBlocks."*".addKeysToAgent = "yes";
      # the key authorized on every host; the Macs already carry it in their config
      programs.ssh.matchBlocks."*".identityFile = lib.mkIf pkgs.stdenv.hostPlatform.isLinux ["~/.ssh/personal"];
      services.ssh-agent.enable = pkgs.stdenv.hostPlatform.isLinux;
    };
  };
}
