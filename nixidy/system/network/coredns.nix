{
  nixidy = {charts, ...}: {
    applications.coredns = {
      canivete.bootstrap.enable = true;
      namespace = "kube-system";
      helm.releases.coredns = {
        chart = charts.coredns.coredns;
        values.service.clusterIP = "10.43.0.10";
      };
    };
  };
}
