# The distributed-build pool: one record per box, consumed by the cluster nodes
# (static/builder.nix), the dev host (modules/builders.nix) and `build-all`
# (devenv.nix).
#
#  cores       hardware threads. speedFactor is cores/4 so nix's scheduler (it
#              picks the free slot with the lowest load/speedFactor) hands bigger
#              boxes proportionally more work.
#  jobs        concurrent builds one client may place on the box (the dev host's
#              maxJobs). This is a per-client knob; the real, all-clients ceiling
#              is the nix-daemon cgroup below.
#  quota       CPUQuota (% of one core) on nix-daemon.service. Every build runs
#              inside that cgroup, so it caps ALL builds on the box, whoever asked.
#  buildCores  NIX_BUILD_CORES per build (nix `cores`).
#  memHigh/memMax  cgroup memory throttle / hard cap for builds (an OOM kill
#              takes a build, never etcd or kubelet).
#  etcd        RKE2 server running etcd, which has suffered outages under load.
#
# Etcd servers get 25% of their cores, agents 50%, and dingo (a 4-core etcd
# server with ~4G of RAM to spare) a single core. The small boxes carry the
# lowest weight, and omitting `big-parallel` keeps heavy derivations off them.
# falcon (`falcon` below) is not an RKE2 node and its nix-daemon is configured
# outside this repo (schradert/dotfiles), so no caps are set for it here: when
# that config is merged here it should get the same daemon CPU/IO scheduling.
#
# lan/tailnet are the box's addresses; hostKey pins its ssh host key (also its
# build-client identity towards peers, see static/builder.nix).
let
  node = {
    cores,
    lan,
    tailnet,
    hostKey,
    jobs,
    quota,
    buildCores,
    memHigh,
    memMax,
    etcd ? false,
    big ? false,
  }: {
    inherit cores lan tailnet hostKey jobs quota buildCores memHigh memMax etcd;
    systems = ["x86_64-linux"];
    features =
      ["kvm" "benchmark" "nixos-test"]
      ++ (
        if big
        then ["big-parallel"]
        else []
      );
    speedFactor = cores / 4;
    user = "nix-remote-builder";
  };
in {
  nodes = {
    sirver = node {
      cores = 64;
      lan = "192.168.50.204";
      tailnet = "100.64.0.2";
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMZHuAa6lN+oXGgR7QbNP+5WZcXuzq9E7EFCvh4dgNOK";
      jobs = 8;
      quota = 1600;
      buildCores = 4;
      memHigh = "32G";
      memMax = "48G";
      etcd = true;
      big = true;
    };
    octopus = node {
      cores = 32;
      lan = "192.168.50.53";
      tailnet = "100.64.0.3";
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBra12ioG15PJisgWHxeFjmPixqcbUzRGIi6X4HBQO6U";
      jobs = 4;
      quota = 800;
      buildCores = 4;
      memHigh = "24G";
      memMax = "32G";
      etcd = true;
      big = true;
    };
    dingo = node {
      cores = 4;
      lan = "192.168.50.105";
      tailnet = "100.64.0.6";
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKuAcWbXCyB821rWE2H1LNRp0aUEvFEqweAAIKzX2j3G";
      jobs = 1;
      quota = 100;
      buildCores = 1;
      memHigh = "2G";
      memMax = "3G";
      etcd = true;
    };
    bonobo = node {
      cores = 4;
      lan = "192.168.50.142";
      tailnet = "100.64.0.4";
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOE1ODVjUl7u/8lMUUyJzxPjY5Y1NfZcRE6YB7iHmJDv";
      jobs = 1;
      quota = 200;
      buildCores = 2;
      memHigh = "3G";
      memMax = "4G";
    };
    chinchilla = node {
      cores = 4;
      lan = "192.168.50.85";
      tailnet = "100.64.0.5";
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKGwjjOAZmqLT5kuVXdLWpctImvmF5io1IMIEsWsnbdb";
      jobs = 1;
      quota = 200;
      buildCores = 2;
      memHigh = "3G";
      memMax = "4G";
    };
  };

  # Not an RKE2 node: x86_64 natively, aarch64-linux by binfmt emulation (no
  # kvm), reached as its login user. No nix-remote-builder user exists there.
  falcon = {
    cores = 32;
    lan = "192.168.50.215";
    tailnet = "100.64.0.8";
    hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfpkvVrcUgze90HfVLMVsjEUCN3RGynuJC9z4EHKVnA";
    user = "tristan";
    jobs = 12;
    speedFactor = 8;
    systems = ["x86_64-linux" "i686-linux"];
    features = ["benchmark" "big-parallel" "kvm" "nixos-test"];
    emulated = {
      systems = ["aarch64-linux"];
      features = ["benchmark" "big-parallel"];
      speedFactor = 2;
    };
  };
}
