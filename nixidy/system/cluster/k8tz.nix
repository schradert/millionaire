{
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.k8tz = {
      namespace = "kube-system";
      helm.releases.k8tz = {
        chart = pinned.charts.k8tz;
        values = {
          namespace = null;
          timezone = "America/Los_Angeles";
          cronJobTimeZone = true;
          image = {
            inherit (pinned.images.k8tz) repository;
            tag = with pinned.images.k8tz; "${tag}@${digest}";
          };
          replicaCount = 2;
          affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = lib.toList {
            weight = 1;
            podAffinityTerm.labelSelector.matchLabels."app.kubernetes.io/name" = "k8tz";
            podAffinityTerm.topologyKey = "kubernetes.io/hostname";
          };
          # Pods still schedule (in UTC) while the webhook is down.
          webhook.failurePolicy = "Ignore";
          webhook.certManager = {
            enabled = true;
            issuerRef = {
              name = "k8tz-webhook";
              kind = "Issuer";
            };
          };
        };
      };
      resources.issuers.k8tz-webhook.spec.selfSigned = {};
      # The chart's health test can run before the webhook is up; let it retry.
      resources.pods.k8tz-health-test.spec.restartPolicy = lib.mkForce "OnFailure";
    };
  };
}
