# The dev host's view of the distributed-build pool (static/builders.nix): every
# box is a nix.buildMachines entry, weighted by cores via speedFactor, and
# reached by an ssh Host of the same name.
#
# Routing, per host: direct to its LAN IP when that answers (1s probe), else a
# ProxyJump through the edge box (192.184.168.248 forwards to sirver, which
# reaches the rest of the LAN). Parallel builds multiplex over one connection
# (ControlMaster) so they do not trip sshd's MaxStartups, and every host key is
# pinned. Cluster nodes are used as `nix-remote-builder` (forced command
# `nix-daemon --stdio`, authorized for the personal key by static/k8s-node.nix);
# falcon is also the dev host's login and `build-all --remote` box, so it is
# used as tristan.
#
# Node names: nix-darwin has no `networking.hosts` at the locked rev, so an
# activation script keeps a marked block in /etc/hosts. Bare names are LAN addresses
# (the attic substituter is http://chinchilla:8199), `<name>.tailnet` the tailnet ones, as on
# the nodes themselves (static/builder.nix). falcon's tailnet IP changes, so it is LAN only.
#
# The caps that keep builds from starving etcd live on the nodes themselves
# (static/builder.nix); maxJobs here is only this client's share.
{
  darwin = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: let
    pool = import ../static/builders.nix;
    inherit (flake.config.canivete.meta.people) me;
    key = "/Users/${me}/.ssh/personal";
    jump = "${me}@192.184.168.248";
    hosts = pool.nodes // {inherit (pool) falcon;};
    builders = pool.builders // {inherit (pool) falcon;};
    nodeHosts = pkgs.writeText "node-hosts" (lib.concatLines (lib.flatten (lib.mapAttrsToList (n: p:
      ["${p.lan} ${n}"] ++ lib.optional (p ? tailnet && n != "falcon") "${p.tailnet} ${n}.tailnet")
    (hosts // {inherit (pool) axolotl;}))));

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
        lib.mapAttrsToList machine builders
        ++ [emulated];

      system.activationScripts.extraActivation.text = ''
        echo "updating node names in /etc/hosts..." >&2
        { /usr/bin/awk '/^# BEGIN nix-darwin node hosts$/ {skip = 1} !skip {print} /^# END nix-darwin node hosts$/ {skip = 0}' /etc/hosts
          echo "# BEGIN nix-darwin node hosts"; cat ${nodeHosts}; echo "# END nix-darwin node hosts"; } > /etc/hosts.nix-darwin
        cat /etc/hosts.nix-darwin > /etc/hosts && rm /etc/hosts.nix-darwin
      '';

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
