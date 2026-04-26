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
  nixidy = {charts, lib, ...}: {
    applications.multus = {
      namespace = "kube-system";
      helm.releases.multus = {
        chart = lib.helm.downloadHelmChart {
          chart = "multus";
          version = "7.0.0";
          repo = "https://angelnu.github.io/helm-charts";
          chartHash = "sha256-q/mAaYLr8idMWsqERsEDs/29B9FInANTbu08mMta76k=";
        };
        values = {
          # The thick-plugin DaemonSet OOMs at the upstream default of 50Mi
          # (k8snetworkplumbingwg/multus-cni#1244). Bump to a sane size.
          controllers.multus.containers.multus = {
            resources.requests.memory = "100Mi";
            resources.limits.memory = "200Mi";
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
