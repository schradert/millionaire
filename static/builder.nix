# Cluster node as a member of the distributed-build pool (static/builders.nix):
# protect the cluster from builds.
#
# sirver, octopus and dingo run etcd, which has suffered outages under load, and
# every node runs kubelet. Builds (ours and everyone else's: remote clients are
# proxied into this same daemon) all execute inside nix-daemon.service, so that
# one cgroup is where the caps live: SCHED_IDLE CPU + idle IO class so builds only
# use cycles nothing else wants, a CPU quota (25% of cores on etcd servers, 50% on
# agents), a memory throttle/limit, and a high OOM score so the kernel kills a
# build before etcd or kubelet.
{
  config,
  lib,
  ...
}: let
  me = (import ./builders.nix).nodes.${config.networking.hostName};
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
}
