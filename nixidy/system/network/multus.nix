{...}: {
  # Multus CNI: meta-plugin that lets pods attach a second NIC alongside Cilium's
  # primary eth0. Required for any pod that needs L2 multicast or a real LAN IP —
  # currently just Music Assistant (mDNS speaker discovery), but the same
  # NetworkAttachmentDefinition can serve future apps with the same need.
  #
  # ROLLOUT — phase 1 proved multus on sirver alone; phase 2 (2026-06-26)
  # widened the DaemonSet + uninstall Job cluster-wide so multus runs on every
  # node and any node can host pods that attach NADs. The `cni-dhcp` node daemon
  # (below) deliberately STAYS sirver-only: the sole DHCP-IPAM NAD (home-lan) is
  # `master: br0`, and only sirver has br0 — running the daemon elsewhere is dead
  # weight plus an extra etcd-server node touch. Extend it (drop the hostname
  # gate) only when a NAD targets another node's NIC. Rollback that doesn't
  # depend on the cluster: `rm /etc/cni/net.d/00-multus.conf` on a node restores
  # pure-cilium CNI for new pod sandboxes (running pods unaffected either way).
  #
  # Why this is safe to merge given the 2026-06-11 etcd pipe-freeze outage: that
  # outage was armed by a CNI-involved deploy (#40) restarting all three RKE2
  # *servers* near-simultaneously, freezing etcd on full log pipes. NOTHING here
  # restarts rke2-server. The ArgoCD side rolls the cilium agent DaemonSet
  # (staggered, as every cilium config change does) and adds this sirver-only
  # multus DaemonSet; etcd/apiserver are static pods on hostNetwork, untouched by
  # CNI. The single node-config touch is cni-dhcp, shipped by a manual `pulumi up`
  # (adding a systemd unit doesn't bounce rke2-server) — but per the incident
  # lesson, still apply node configs one at a time, never all servers at once.
  #
  # Facts this config rests on (verified on sirver, 2026-06-11):
  #   - NixOS RKE2's containerd config carries no CNI path overrides, so it uses
  #     the containerd stock paths /etc/cni/net.d + /opt/cni/bin — NOT the
  #     /var/lib/rancher/{rke2,k3s}/... paths the chart defaults to. Cilium's
  #     05-cilium.conflist lives in /etc/cni/net.d and cilium-cni in /opt/cni/bin.
  #   - Cilium defaults to cni.exclusive=true, i.e. it reaps any other config in
  #     /etc/cni/net.d — it would delete the 00-multus.conf the thick-plugin
  #     daemon generates. cilium.nix sets cni.exclusive=false to reconcile.
  #   - `br0` exists and is UP on sirver (it's also a cilium L2 announce device).
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: {
    # Scoped to sirver: the only DHCP-IPAM NAD (home-lan) is a macvlan on `br0`,
    # which only sirver has. multus itself is cluster-wide (phase 2), but the
    # dhcp daemon is only useful where such a NAD is consumed — so it stays here
    # until a NAD targets another node's NIC (then drop this hostname gate).
    config = lib.mkIf (config.canivete.kubernetes.enable && config.networking.hostName == "sirver") {
      # The home-lan NAD uses `ipam.type = "dhcp"`, and that CNI plugin is only a
      # thin client: a persistent `dhcp daemon` must serve /run/cni/dhcp.sock on
      # the node and run the DHCP exchange for pod interfaces. The chart installs
      # plugin binaries but nothing provides the daemon, so it lives here. DHCP
      # (not static/host-local) is deliberate: the router's DHCP pool spans the
      # whole /24 (see docs/network-audit-2026-03-16.md), so only the router can
      # hand out collision-free LAN addresses. Ships with the next pulumi node
      # deploy — until then the pod's macvlan attachment fails IPAM.
      systemd.services.cni-dhcp = {
        description = "CNI dhcp IPAM daemon";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/cni/dhcp.sock";
          ExecStart = "${pkgs.cni-plugins}/bin/dhcp daemon";
          Restart = "always";
          RuntimeDirectory = "cni";
        };
      };
    };
  };
  nixidy = {
    lib,
    pkgs,
    ...
  }: {
    # Register the NetworkAttachmentDefinition CRD with nixidy's schema so NADs
    # are typed resources (same pattern as cilium-crds / volsync-crds). The chart
    # ships an identical CRD in crds/, but includeCRDs=false below keeps ownership
    # solely here.
    applications.multus-crds.namespace = "kube-system";
    canivete.crds.multus = {
      application = "multus-crds";
      install = true;
      prefix = "artifacts";
      # artifacts/ also carries a sample NAD and the legacy v1beta1 CRD —
      # only take the v1 CRD.
      match = ".*networks-crd\\.yaml";
      # The generator derives the attr name from the CRD's plural, which is
      # hyphenated for NADs — override to idiomatic camelCase.
      attrNameOverrides."network-attachment-definitions.k8s.cni.cncf.io" = "networkAttachmentDefinitions";
      src = pkgs.fetchFromGitHub {
        owner = "k8snetworkplumbingwg";
        repo = "network-attachment-definition-client";
        rev = "v1.7.7";
        hash = "sha256-o5Gxm+lXZVPiWeOyEt8zKrGSRj4ZR60NT1DQASXe6gI=";
      };
    };
    applications.multus = {
      namespace = "kube-system";
      helm.releases.multus = {
        chart = lib.helm.downloadHelmChart {
          chart = "multus";
          version = "7.0.0";
          repo = "https://angelnu.github.io/helm-charts";
          # angelnu re-publishes the 7.0.0 tarball in place periodically (a
          # mutable tag — old bytes vanish from the repo), so this chartHash
          # drifts and must be re-pinned each time, re-verifying the render
          # after since content can shift. Currently: common library 5.0.1,
          # appVersion 4.3.0 (rendered image multus-cni:4.3.0-thick). Values
          # below are adapted for common 5.x behavior.
          chartHash = "sha256-PeTWH+uuuTzurk2fV2ewhqOPHindpmL3OE1gIY4XgsM=";
        };
        # The CRD is owned by the multus-crds application above.
        includeCRDs = false;
        values = {
          # The chart defaults to K3S hostPaths; see the verified-facts comment
          # at the top of this file for why these are the right paths here. The
          # config dir doubles as multusAutoconfigDir, where the thick-plugin
          # daemon discovers cilium's conflist and generates 00-multus.conf
          # wrapping it (00- sorts before 05-cilium, so containerd picks it).
          cni.paths = {
            config = "/etc/cni/net.d";
            bin = "/opt/cni/bin";
          };
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
              # The chart derives the image tag from appVersion
              # ({{.Chart.AppVersion}}-thick), but multus-cni publishes NO
              # versioned 4.x -thick image (the re-published chart's appVersion
              # 4.3.0 → multus-cni:4.3.0-thick is a 404). Pin the project's
              # rolling stable-thick by digest; the chart's multus-installer
              # init container reuses .tag, resolving to the same image.
              image = {
                repository = "ghcr.io/k8snetworkplumbingwg/multus-cni";
                tag = "stable-thick";
                digest = "sha256:2b9671447f3ea4e7e56730843dbf59445b9307246f393b61386b896d56ae51c9";
              };
              resources.requests.memory = "100Mi";
              resources.limits.memory = "200Mi";
            };
            pod = {
              # The new common defaults this to false; the thick-plugin daemon
              # needs its SA token to read NADs/pod annotations via the API.
              automountServiceAccountToken = true;
              # Phase 2: cluster-wide — no nodeSelector, multus on every node.
            };
          };
          # Helm test hooks never run under ArgoCD, and the chart's test NAD
          # renders broken anyway (the test Job references a "multus-test" NAD
          # while the rawResource is named "multus").
          controllers.test.enabled = false;
          rawResources.test.enabled = false;
          # The uninstall Job stays (ArgoCD honors helm.sh/hook pre-delete, so
          # deleting the app sweeps multus's files off a node). Single Job, not a
          # DaemonSet, so cleanup is best-effort one-node — acceptable.
        };
      };
      # Secondary-NIC definition for pods on the home LAN: macvlan subinterface
      # of br0 in bridge mode, addressed by the router via DHCP (requires the
      # cni-dhcp daemon above). Lives in `media` for music-assistant; macvlan
      # means the pod talks to every LAN host *except* sirver itself.
      resources.networkAttachmentDefinitions.home-lan = {
        metadata.namespace = "media";
        spec.config = builtins.toJSON {
          cniVersion = "0.3.1";
          name = "home-lan";
          type = "macvlan";
          master = "br0";
          mode = "bridge";
          ipam.type = "dhcp";
        };
      };
    };
  };
}
