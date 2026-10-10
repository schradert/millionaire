# Cluster node as a member of the distributed-build pool (static/builders.nix).
#
# 1. Protect the cluster. sirver, octopus and dingo run etcd, which has suffered
#    outages under load, and every node runs kubelet. Builds (ours and everyone
#    else's: remote clients are proxied into this same daemon) all execute inside
#    nix-daemon.service, so that one cgroup is where the caps live: SCHED_IDLE
#    CPU + idle IO class so builds only use cycles nothing else wants, a CPU
#    quota (25% of cores on etcd servers, 50% on agents), memory throttle/limit
#    and a high OOM score so the kernel kills a build before etcd or kubelet.
#
# 2. Build for each other. Peers are reached by `<node>.tailnet` aliases (headscale
#    has magic_dns off and nodes run accept-dns=false, so tailnet names do not
#    resolve on their own; the bare node names are deliberately NOT aliased, they
#    are what rke2 and attic use). A node's own ssh host key is its client
#    identity: every peer authorizes the others' host keys for nix-remote-builder,
#    so no secret needs provisioning. falcon's host key is authorized too so its
#    daemon can fan `build-all` out to the nodes (falcon itself has no
#    nix-remote-builder user, so nodes cannot yet use it as a builder: that
#    needs a change in falcon's own config, schradert/dotfiles).
{
  config,
  lib,
  ...
}: let
  pool = import ./builders.nix;
  name = config.networking.hostName;
  me = pool.nodes.${name};
  peers = lib.filterAttrs (n: _: n != name) pool.nodes;
  alias = n: "${n}.tailnet";
in {
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
  nix.daemonIOSchedPriority = 7;
  systemd.services.nix-daemon.serviceConfig = {
    CPUQuota = "${toString me.quota}%";
    CPUWeight = 10;
    IOWeight = 10;
    MemoryHigh = me.memHigh;
    MemoryMax = me.memMax;
    OOMScoreAdjust = lib.mkForce 500;
  };
  nix.settings = {
    cores = me.buildCores;
    max-jobs = me.jobs;
  };

  networking.hosts = lib.mapAttrs' (n: p: lib.nameValuePair p.tailnet [(alias n)]) peers;
  programs.ssh.knownHosts =
    lib.mapAttrs' (n: p:
      lib.nameValuePair "builder-${n}" {
        hostNames = [(alias n) p.tailnet];
        publicKey = p.hostKey;
      })
    peers;
  roles.nix-remote-builder.schedulerPublicKeys = map (p: p.hostKey) (lib.attrValues peers) ++ [pool.falcon.hostKey];
  # A remote client's build runs in this node's daemon, which would otherwise
  # re-dispatch it through its own `builders` below (hopping it onward to a weaker
  # peer and back). The forced command starts the daemon proxy with builders
  # emptied, so builds that arrive over ssh always run here.
  users.users.nix-remote-builder.openssh.authorizedKeys.keys = lib.mkForce (map
    (key: ''restrict,command="nix-daemon --stdio --option builders \"\"" ${key}'')
    config.roles.nix-remote-builder.schedulerPublicKeys);

  nix.distributedBuilds = true;
  nix.buildMachines =
    lib.mapAttrsToList (n: p: {
      hostName = alias n;
      sshUser = p.user;
      sshKey = "/etc/ssh/ssh_host_ed25519_key";
      protocol = "ssh-ng";
      inherit (p) systems speedFactor;
      supportedFeatures = p.features;
      maxJobs = p.jobs;
    })
    peers;
}
