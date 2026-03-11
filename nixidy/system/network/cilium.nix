{lib, ...}: {
  imports = [./gateway.nix];
  devenv = {pkgs, ...}: {packages = [pkgs.cilium-cli];};
  nixos = {
    config,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.canivete.kubernetes.enable {
      # TODO are all of these necessary?
      boot.blacklistedKernelModules = ["netfilter"];
      boot.kernelModules = ["cls_bpf" "sch_ingress" "crypto_user" "iptable_raw" "xt_socket"];
      environment.systemPackages = [pkgs.bpftop];
      networking.firewall.trustedInterfaces = ["cilium+" "lxc+"];
      # TODO avoid firewall deactivation to simplify config with cilium
      networking.firewall.enable = lib.mkForce false;
    };
  };
  nixidy = {
    charts,
    pkgs,
    ...
  }: let
    chart = charts.cilium.cilium;
    devices = ["br0"];
  in {
    applications.cilium-crds.namespace = "kube-system";
    canivete.crds.cilium = {
      application = "cilium-crds";
      install = true;
      prefix = "pkg/k8s/apis/cilium.io/client/crds";
      src = pkgs.fetchFromGitHub {
        owner = "cilium";
        repo = "cilium";
        hash = "sha256-wswY4u2Z7Z8hvGVnLONxSD1Mu1RV1AglC4ijUHsCCW4=";
        rev = let
          chartJSON = pkgs.runCommand "Chart.json" {} "${pkgs.yq}/bin/yq -r '.' ${chart + "/Chart.yaml"} > $out";
        in
          (lib.importJSON chartJSON).appVersion;
      };
    };
    applications.cilium = {
      imports = [
        {
          # Prometheus
          canivete.bootstrap.exclude = map (name: "monitoring.coreos.com/v1/ServiceMonitor/${name}") [
            "cilium-agent"
            "cilium-envoy"
            "cilium-operator"
            "hubble-relay"
          ];
          helm.releases.cilium.values = {
            envoy.prometheus.serviceMonitor.enabled = true;
            hubble.metrics.serviceMonitor.enabled = true;
            hubble.relay.prometheus.serviceMonitor.enabled = true;
            operator.prometheus.serviceMonitor.enabled = true;
            prometheus.serviceMonitor.enabled = true;
            prometheus.serviceMonitor.trustCRDsExist = true;
          };
        }
        {
          # Overrides
          # TODO why do I have to do this?!
          resources.namespaces.cilium-secrets.metadata.annotations = lib.mkForce {"argocd.argoproj.io/sync-options" = "Prune=confirm";};
        }
      ];
      canivete.bootstrap.enable = true;
      namespace = "kube-system";
      helm.releases.cilium = {
        inherit chart;
        values = {
          autoDirectNodeRoutes = true;
          dashboards.enabled = true;
          inherit devices;
          envoy.rollOutPods = true;
          externalIPs.enabled = true;
          hubble = {
            metrics.dashboards.enabled = true;
            relay.enabled = true;
            relay.rollOutPods = true;
            relay.prometheus.enabled = true;
            ui.enabled = true;
            ui.rollOutPods = true;
            # Avoid Secrets in GitOps
            tls.auto.method = "cronJob";
          };
          ipv4NativeRoutingCIDR = "10.0.0.0/8";
          kubeProxyReplacement = true;
          k8sServiceHost = "127.0.0.1";
          k8sServicePort = 6443;
          l2announcements.enabled = true;
          operator = {
            dashboards.enabled = true;
            prometheus.enabled = true;
            replicas = 1;
            rollOutPods = true;
          };
          prometheus.enabled = true;
          rollOutCiliumPods = true;
          routingMode = "native";
        };
      };
      resources.ciliumL2AnnouncementPolicies.default.spec = {
        externalIPs = true;
        loadBalancerIPs = true;
        interfaces = devices;
      };
      resources.ciliumLoadBalancerIPPools.home-pool.spec = {
        blocks = lib.toList {
          start = "192.168.50.240";
          stop = "192.168.50.254";
        };
      };
    };
  };
}
