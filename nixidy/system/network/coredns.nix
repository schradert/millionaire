{
  nixidy = {
    charts,
    lib,
    ...
  }: {
    nixidy.charts.coredns.coredns = lib.helm.downloadHelmChart {
      chart = "coredns";
      version = "1.45.0";
      repo = "https://coredns.github.io/helm";
      chartHash = "sha256-x701G/86Q+PqGYfD6Mo2c5Y1WeXKDRXOvwqjUYCYqp0=";
    };
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
