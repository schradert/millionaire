# What makes a host an RKE2 cluster node (agent unless `services.rke2.role` says
# otherwise), independent of what else the box is (headless server: ./server.nix):
# RKE2 + canivete wiring, cluster tailnet, build-pool membership, clock, resolver
# and attic cache. Disk layout is separate (modules/disko.nix).
{
  config,
  flake,
  lib,
  pkgs,
  ...
}: let
  containerdDir = "/var/lib/rancher/rke2/agent/containerd";
  isServer = config.services.rke2.role == "server";
in {
  imports = [./builder.nix ./tailnet.nix ./rke2-fips-overlay.nix ./etcd-watchdog.nix ./etcd-snapshot.nix ./containerd-external.nix] ++ (with flake.inputs.srvos.nixosModules; [roles-nix-remote-builder]);
  canivete.kubernetes.enable = true;
  # Join the cluster tailnet so cloud burst workers can reach the RKE2
  # supervisor and pod traffic routes natively across sites (no MagicDNS,
  # no accept-routes — see tailnet.nix for the routing rationale).
  tailnet.enable = true;
  tailnet.podSupernetRoute = true;
  # Nothing consumes pod routes over the tailnet (docs/tailscale-integration.md, "Pod routes"): withdraw them
  # at each node's deploy. cloud-worker.nix imports tailnet.nix, not this file, so burst workers keep theirs.
  tailnet.podRoutes = lib.mkDefault false;
  # TODO how should I handle the scheduler from scratch?
  canivete.kubernetes.yaml.disable-scheduler = lib.mkForce false;
  environment.systemPackages = [pkgs.kubectl];
  # TODO use 9345 supervisor port upstream for RKE2
  canivete.kubernetes.yaml.server = lib.mkForce "https://sirver:9345";
  # kubelet copies the node's resolv.conf search domains into pods, so tailscale's
  # ts.trdos.me collides with CoreDNS's *.trdos.me wildcard (coredns.nix) and pods
  # resolve external names to the gateway VIP. Give kubelet a tailnet-search-free resolv.conf.
  environment.etc."rke2-resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 1.0.0.1
  '';
  canivete.kubernetes.yaml.kubelet-arg = [
    "resolv-conf=/etc/rke2-resolv.conf"
    # Serving cert from a kubernetes.io/kubelet-serving CSR (approved by
    # kubelet-csr-approver) instead of the static one RKE2 writes at start.
    "rotate-server-certificates=true"
  ];
  # Servers' kubelets talk to their local apiserver, so an etcd stall (octopus's ZFS/HDD etcd
  # during a rollout burst, 2026-10-11) makes lease renewals fail and evicted 116 pods. The
  # grace period must be N x kubelet node-status-update-frequency (10s): 2m = 12 retries
  # (default 40s). Pods tolerate not-ready/unreachable for 10m (default 5m) before eviction.
  # Cost: a truly dead node takes ~12m instead of ~6m to fail over (medik8s, todo 7, is the
  # proper answer).
  canivete.kubernetes.yaml.kube-controller-manager-arg = lib.mkIf isServer ["node-monitor-grace-period=2m"];
  canivete.kubernetes.yaml.kube-apiserver-arg = lib.mkIf isServer [
    "default-not-ready-toleration-seconds=600"
    "default-unreachable-toleration-seconds=600"
  ];
  # Nodes don't use tailnet DNS (accept-dns=false), so internal-only names
  # containerd pulls from must resolve locally: the internal gateway fronts Harbor.
  networking.hosts."192.168.50.241" = ["harbor.trdos.me"];
  # The upstream unit sets TimeoutStartSec=0, which let rke2-server sit "activating"
  # for months (Type=notify never signalled ready). Bound it so systemd kills the
  # hung start; Restart=always (upstream) then retries it.
  systemd.services = lib.mkMerge [
    {rke2-server.serviceConfig.TimeoutStartSec = lib.mkForce "15min";}
    # Start rke2 after the containerd dataset mount below. Ordering only, and the mount is
    # nofail: a node that has not been migrated yet keeps running on the old directory
    # instead of failing to start rke2. (A dynamic key cannot sit beside the static one
    # in a single attrset, hence mkMerge.)
    {"rke2-${config.services.rke2.role}".after = ["var-lib-rancher-rke2-agent-containerd.mount"];}
  ];
  # Image layers and snapshots are disposable and re-pullable, so they get their own
  # dataset instead of inheriting root/safe's copies=2 and sync=standard. overlayfs
  # copy-up links each file into place, and ZFS makes that link wait for a txg sync,
  # so an entrypoint that chowns its layer takes hours on the HDD nodes (README todo 55).
  # Existing nodes need the one-shot migration in docs/node-standard.md before the
  # switch that adds this mount; fresh installs get the dataset from disko.
  disko.devices.zpool.root.datasets."local/containerd" = {
    type = "zfs_fs";
    options = {
      mountpoint = "legacy";
      sync = "disabled";
      copies = "1";
      "com.sun:auto-snapshot" = "false";
    };
    mountpoint = containerdDir;
    mountOptions = ["defaults" "nofail"];
  };
  # Ceph mons need <50ms skew; timesyncd (SNTP, 34min polls, random pool servers) drifted ~70ms.
  # chrony disciplines the clock; enabling it disables timesyncd.
  services.chrony = {
    enable = true;
    servers = ["time.cloudflare.com" "0.pool.ntp.org" "1.pool.ntp.org" "2.pool.ntp.org"];
    serverOption = "iburst";
    extraConfig = "makestep 1.0 3";
  };
  # TODO should this be a default?
  # Allows nodes to reach others on the same network by names like `sirver`, etc.
  services.resolved.settings.Resolve.ResolveUnicastSingleLabel = true;

  # Attic binary cache — substitute + auto-push after every build
  # Only enabled once static/generated.json exists (created by Pulumi after attic setup)
  nix.settings = let
    generatedFile = ./generated.json;
    generated =
      if builtins.pathExists generatedFile
      then builtins.fromJSON (builtins.readFile generatedFile)
      else {};
    publicKey = generated.attic_pubkey or null;
    atticEnabled = publicKey != null && publicKey != "";
    attic = "${pkgs.attic-client}/bin/attic";
    hook = pkgs.writeShellScript "attic-push" ''
      set -eu
      set -f # disable globbing
      [ -f /run/secrets/attic-auth-token ] || exit 0
      ATTIC_TOKEN=$(cat /run/secrets/attic-auth-token)
      ${pkgs.coreutils}/bin/timeout 20 ${attic} login --set-default main "http://chinchilla:8199" "$ATTIC_TOKEN" 2>/dev/null || exit 0
      if [ -n "''${OUT_PATHS:-}" ]; then
        # post-build-hook blocks the build until it returns: never let a slow cache stall builds
        ${pkgs.coreutils}/bin/timeout 120 ${attic} push main $OUT_PATHS 2>/dev/null || true
      fi
    '';
  in
    lib.mkIf atticEnabled {
      substituters = ["http://chinchilla:8199/main"];
      trusted-public-keys = [publicKey];
      # attic lives on one host (chinchilla, static/attic-server.nix): bound every wait on it so a hung cache
      # is skipped instead of stalling activations (home-manager hit its 10-minute timeout at boot).
      connect-timeout = 5;
      stalled-download-timeout = 60;
      fallback = true;
      post-build-hook = toString hook;
    };
  # Pilot of modules/bws-secrets.nix (docs/secrets.md): with bwsSecrets.enable the same file is fetched from Bitwarden.
  sops.secrets = lib.mkIf (builtins.pathExists ./generated.json && !config.bwsSecrets.enable) {attic-auth-token.key = "attic/auth-token";};
  bwsSecrets.secrets = lib.mkIf (builtins.pathExists ./generated.json) {attic-auth-token.key = "attic/auth-token";};
  # TODO move over old dotfiles modules
  # dotfiles.profiles.server.enable = true;
}
