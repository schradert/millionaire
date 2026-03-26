{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {charts, ...}: {
    applications.coredns = {
      canivete.bootstrap.enable = true;
      namespace = "kube-system";
      helm.releases.coredns = {
        chart = charts.coredns.coredns;
        values = {
          service.clusterIP = "10.43.0.10";
          servers = [
            # Forward trdos.me queries to AdGuard Home so in-cluster services
            # resolve internal hostnames to the internal gateway
            {
              zones = [{zone = "${domain}."; use_tcp = true;}];
              port = 53;
              plugins = [
                {name = "forward"; parameters = "${domain} 192.168.50.242";}
                {name = "cache"; parameters = "30";}
              ];
            }
            # Default server block (matches chart defaults)
            {
              zones = [{zone = "."; use_tcp = true;}];
              port = 53;
              plugins = [
                {name = "errors";}
                {name = "health"; configBlock = "lameduck 10s";}
                {name = "ready";}
                {
                  name = "kubernetes";
                  parameters = "cluster.local in-addr.arpa ip6.arpa";
                  configBlock = "pods insecure\nfallthrough in-addr.arpa ip6.arpa\nttl 30";
                }
                {name = "prometheus"; parameters = "0.0.0.0:9153";}
                {name = "forward"; parameters = ". /etc/resolv.conf";}
                {name = "cache"; parameters = "30";}
                {name = "loop";}
                {name = "reload";}
                {name = "loadbalance";}
              ];
            }
          ];
        };
      };
    };
  };
}
