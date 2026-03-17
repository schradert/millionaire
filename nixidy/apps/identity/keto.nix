{...}: {
  nixidy = {lib, ...}: {
    applications.keto = {
      namespace = "identity";
      postgres.enable = true;
      postgres.database = "keto";

      helm.releases.keto = {
        chart = lib.helm.downloadHelmChart {
          chart = "keto";
          version = "0.60.1";
          repo = "https://k8s.ory.sh/helm/charts";
          chartHash = "sha256-XHmMrq1ufD/Lik+Qb6saFnTISxvc3V8We4Utfv3P0EA=";
        };
        values = {
          keto = {
            automigration = {
              enabled = true;
              type = "initContainer";
            };

            config = {
              dsn = "postgres://keto:$(DB_PASSWORD)@keto-rw.identity.svc.cluster.local:5432/keto?sslmode=disable";

              namespaces = [
                {name = "apps"; id = 0;}
                {name = "groups"; id = 1;}
              ];
            };
          };

          deployment.extraEnv = lib.toList {
            name = "DB_PASSWORD";
            valueFrom.secretKeyRef = {
              name = "keto";
              key = "db_password";
            };
          };

          job.extraEnv = lib.toList {
            name = "DB_PASSWORD";
            valueFrom.secretKeyRef = {
              name = "keto";
              key = "db_password";
            };
          };
        };
      };

      resources.externalSecrets.keto.spec.data = lib.toList {
        secretKey = "db_password";
        remoteRef = {
          key = "keto-app";
          property = "password";
        };
        sourceRef.storeRef = {
          name = "kubernetes-identity";
          kind = "ClusterSecretStore";
        };
      };
    };
  };
}
