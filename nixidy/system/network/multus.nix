{...}: {
  # Multus CNI: meta-plugin that lets pods attach a second NIC alongside Cilium's
  # primary eth0. Required for any pod that needs L2 multicast or a real LAN IP —
  # currently just Music Assistant (mDNS speaker discovery), but the same
  # NetworkAttachmentDefinition can serve future apps with the same need.
  #
  # STAGED: this module is intentionally not yet imported from nixidy/system/default.nix.
  # Cluster-wide CNI changes warrant separate testing per the user's "no untested infra
  # changes" preference. Enable this and music-assistant.nix together once tested.
  #
  # When enabling, two follow-ups are required:
  #
  #   1. Register the NetworkAttachmentDefinition CRD with nixidy's schema, mirroring
  #      the cilium-crds / volsync-crds pattern (canivete.crds.<name> with src =
  #      pkgs.fetchFromGitHub { owner = "k8snetworkplumbingwg";
  #      repo = "network-attachment-definition-client"; rev = "..."; hash = "..."; }
  #      and prefix = "artifacts"). Once registered, you'll be able to declare the
  #      home-lan NAD here (see commented sketch below).
  #
  #   2. Confirm `br0` exists on the target node (sirver) and is on the speaker VLAN.
  #      Update the macvlan `master` value in the NAD if a different bridge is needed.
  nixidy = {lib, ...}: {
    applications.multus = {
      namespace = "kube-system";
      helm.releases.multus = {
        chart = lib.helm.downloadHelmChart {
          chart = "multus";
          version = "7.0.0";
          repo = "https://angelnu.github.io/helm-charts";
          # Upstream republished the 7.0.0 tarball in place (old bytes are
          # gone from the repo): newer embedded common library (5.0.1) and an
          # appVersion bump 4.2.3 → 4.2.4 (so the rendered image becomes
          # multus-cni:4.2.4-thick). Hash updated to match; values adapted
          # below for the new common's behavior changes.
          chartHash = "sha256-mrJV0KBu+BEhJCe2/d4vBqwFr0Qu1oT93ZKAv3ckcls=";
        };
        values = {
          # The new common injects an implicit release-name SA on top of the
          # chart's own "multus" SA, leaving every controller unable to
          # auto-pick between two SAs. Disable the implicit one — render then
          # matches the previous wiring (single "multus" SA on all
          # controllers).
          global.createDefaultServiceAccount = false;
          # The thick-plugin DaemonSet OOMs at the upstream default of 50Mi
          # (k8snetworkplumbingwg/multus-cni#1244). Bump to a sane size.
          controllers.multus = {
            containers.multus = {
              resources.requests.memory = "100Mi";
              resources.limits.memory = "200Mi";
            };
            # The new common defaults this to false; the thick-plugin daemon
            # needs its SA token to read NADs/pod annotations via the API.
            pod.automountServiceAccountToken = true;
          };
        };
      };
      # Sketch of the home-lan NetworkAttachmentDefinition once the CRD is registered.
      # Uncomment after step (1) above is wired up.
      #
      # resources.networkAttachmentDefinitions.home-lan = {
      #   metadata.namespace = "media";
      #   spec.config = builtins.toJSON {
      #     cniVersion = "0.3.1";
      #     name = "home-lan";
      #     type = "macvlan";
      #     master = "br0";
      #     mode = "bridge";
      #     ipam.type = "dhcp";
      #   };
      # };
    };
  };
}
