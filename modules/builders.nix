# The dev host's view of the distributed-build pool (static/builders.nix): every
# box is a nix.buildMachines entry, weighted by cores via speedFactor, and
# reached by an ssh Host of the same name.
#
# Routing, per host: direct to its LAN IP when that answers (1s probe), else a
# ProxyJump through the edge box (192.184.168.248 forwards to sirver, which
# reaches the rest of the LAN). Parallel builds multiplex over one connection
# (ControlMaster) so they do not trip sshd's MaxStartups, and every host key is
# pinned. Cluster nodes are used as `nix-remote-builder` (forced command
# `nix-daemon --stdio`, authorized for the personal key by static/server.nix);
# falcon is a login box with no such user, so it is used as tristan.
#
# The caps that keep builds from starving etcd live on the nodes themselves
# (static/builder.nix); maxJobs here is only this client's share.
{
  darwin = {
    config,
    flake,
    lib,
    ...
  }: let
    pool = import ../static/builders.nix;
    inherit (flake.config.canivete.meta.people) me;
    key = "/Users/${me}/.ssh/personal";
    jump = "${me}@192.184.168.248";
    hosts = pool.nodes // {inherit (pool) falcon;};

    machine = name: p: {
      hostName = name;
      sshUser = p.user;
      sshKey = key;
      protocol = "ssh-ng";
      maxJobs = p.jobs;
      inherit (p) systems speedFactor;
      supportedFeatures = p.features;
    };
    # falcon also builds aarch64-linux by binfmt emulation (no kvm, lower weight).
    # Same store URI => both entries share falcon's job slots.
    emulated = machine "falcon" (pool.falcon // pool.falcon.emulated);
  in {
    config = lib.mkIf config.profiles.workstation.enable {
      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;
      nix.buildMachines =
        lib.mapAttrsToList machine hosts
        ++ [emulated];

      programs.ssh.extraConfig =
        lib.concatStrings (lib.mapAttrsToList (name: p: ''
            Match originalhost ${name} !exec "/usr/bin/nc -z -G 1 ${p.lan} 22 >/dev/null 2>&1"
              ProxyJump ${jump}
            Host ${name}
              HostName ${p.lan}
              User ${p.user}
              IdentityFile ${key}
              IdentitiesOnly yes
              ControlMaster auto
              ControlPath ~/.ssh/cm-%C
              ControlPersist 60
          '')
          hosts)
        + ''
          Host 192.184.168.248
            IdentityFile ${key}
            IdentitiesOnly yes
        '';
      programs.ssh.knownHosts =
        lib.mapAttrs (name: p: {
          hostNames = [name p.lan];
          publicKey = p.hostKey;
        })
        hosts
        // {
          # The edge box is a port-forward to sirver, so it presents sirver's key.
          edge = {
            hostNames = ["192.184.168.248"];
            publicKey = pool.nodes.sirver.hostKey;
          };
        };
    };
  };
}
