# Jellystat: Jellyfin watch statistics. Admin only: oauth2-proxy (Keycloak `admin` group) is the
# sign-in, and the bootstrap turns Jellystat's own login off, since it has one shared local account
# and no OIDC. JS_USER/JS_PASSWORD stay as the break-glass login (only used if login is re-enabled).
{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "jellystat.${domain}";
    url = "http://jellystat.media.svc.cluster.local:3000";
    generated = name: {
      resources.passwords.${name}.spec = {
        length = 40;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.${name}.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            inherit name;
          };
        };
      };
    };
    fromMediaStore = secretKey: key: property: {
      inherit secretKey;
      remoteRef = {inherit key property;};
      sourceRef.storeRef = {
        name = "kubernetes-media";
        kind = "ClusterSecretStore";
      };
    };
    # The bootstrap Job script (curlimages/curl, busybox sh), idempotent: once Jellystat reports
    # state 2 (user and Jellyfin key set) it exits. First run: a Jellyfin API key named Jellystat
    # (reused if present, minted with the Jellyfin admin session otherwise), the setup calls that
    # Jellystat leaves open until configured, then login off.
    bootstrap = ''
      set -eu
      J=http://jellyfin.media.svc.cluster.local:8096
      S=${url}
      i=0
      until state=$(curl -fsS $S/auth/isConfigured | sed -n 's/.*"state":\([0-9]*\).*/\1/p') && [ -n "$state" ]; do
        i=$((i+1)); [ $i -lt 90 ] || { echo "jellystat did not come up" >&2; exit 1; }
        sleep 5
      done
      if [ "$state" = 2 ]; then echo "jellystat already configured"; exit 0; fi

      tok=$(curl -fsS -X POST $J/Users/AuthenticateByName \
        -H 'Authorization: MediaBrowser Client="jellystat-bootstrap", Device="job", DeviceId="jellystat-bootstrap", Version="1"' \
        -H 'Content-Type: application/json' \
        -d "{\"Username\":\"admin\",\"Pw\":\"$(cat /secrets/jellyfin/password)\"}" \
        | sed -n 's/.*"AccessToken":"\([^"]*\)".*/\1/p')
      [ -n "$tok" ] || { echo "jellyfin admin sign-in failed" >&2; exit 1; }
      findkey() {
        curl -fsS $J/Auth/Keys -H "X-Emby-Token: $tok" | sed 's/},{/}\n{/g' | grep '"AppName":"Jellystat"' \
          | sed -n 's/.*"AccessToken":"\([^"]*\)".*/\1/p' | head -n 1
      }
      key=$(findkey)
      if [ -z "$key" ]; then
        curl -fsS -X POST "$J/Auth/Keys?app=Jellystat" -H "X-Emby-Token: $tok"
        key=$(findkey)
      fi
      [ -n "$key" ] || { echo "no Jellyfin API key for Jellystat" >&2; exit 1; }

      # The local account's password is random and thrown away: nobody signs in with it.
      pw=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
      jwt=$(curl -fsS -X POST $S/auth/createuser -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"$pw\"}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
      [ -n "$jwt" ] || { echo "jellystat createuser returned no token" >&2; exit 1; }
      curl -fsS -X POST $S/auth/configSetup -H 'Content-Type: application/json' \
        -d "{\"JF_HOST\":\"$J\",\"JF_API_KEY\":\"$key\"}" > /dev/null
      curl -fsS -X POST $S/api/setRequireLogin -H "Authorization: Bearer $jwt" \
        -H 'Content-Type: application/json' -d '{"REQUIRE_LOGIN":false}' > /dev/null
      echo "jellystat configured"
    '';
  in {
    portal.apps.jellystat = {
      groups = ["admin"];
      description = "Jellyfin watch statistics";
    };
    gatus.endpoints.jellystat = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    oauth2Proxy.upstreams.${hostname} = {
      inherit url;
      namespace = "media";
      websocket = true;
    };
    applications.jellystat = lib.mkMerge [
      {
        namespace = "media";
        postgres.enable = true;
        helm.releases.jellystat = {
          chart = charts.bjw-s-labs.app-template-patched;
          values = {
            controllers.jellystat = {
              annotations."reloader.stakater.com/auto" = "true";
              containers.jellystat = {
                image = pinned.images.jellystat;
                envFrom = [{secretRef.name = "jellystat";}];
                env.TZ = "Etc/UTC";
                resources = {
                  requests = {
                    cpu = "25m";
                    memory = "256Mi";
                  };
                  limits.memory = "768Mi";
                };
                probes.liveness.enabled = true;
                probes.readiness.enabled = true;
                probes.startup = {
                  enabled = true;
                  spec.failureThreshold = 60;
                };
              };
            };
            service.jellystat.ports.http.port = 3000;
            persistence.backup-data = {
              type = "emptyDir";
              globalMounts = [{path = "/app/backend/backup-data";}];
            };
            route.jellystat = {
              hostnames = [hostname];
              parentRefs = lib.toList {
                name = "internal";
                namespace = "kube-system";
                sectionName = "https";
              };
              rules = lib.toList {
                backendRefs = lib.toList {
                  name = "oauth2-proxy";
                  namespace = "identity";
                  port = 4180;
                };
              };
            };
          };
        };
        resources.externalSecrets.jellystat.spec = {
          data = [
            (fromMediaStore "DB_PASSWORD" "jellystat-app" "password")
            (fromMediaStore "JWT_SECRET" "jellystat-jwt" "password")
            (fromMediaStore "ADMIN_PASSWORD" "jellystat-admin" "password")
          ];
          target.template.data = {
            POSTGRES_USER = "jellystat";
            POSTGRES_PASSWORD = "{{ .DB_PASSWORD }}";
            POSTGRES_IP = "jellystat-rw.media.svc.cluster.local";
            POSTGRES_PORT = "5432";
            POSTGRES_DB = "jellystat";
            JWT_SECRET = "{{ .JWT_SECRET }}";
            JS_USER = "admin";
            JS_PASSWORD = "{{ .ADMIN_PASSWORD }}";
          };
        };
        resources.pushSecrets.jellystat-admin.spec = {
          secretStoreRefs = lib.toList {
            name = "bitwarden";
            kind = "ClusterSecretStore";
          };
          selector.secret.name = "jellystat-admin";
          data = lib.toList {
            match = {
              secretKey = "password";
              remoteRef.remoteKey = "jellystat/admin-password";
            };
          };
        };
        # Jellystat stores whatever the setup calls hand it, and with login off any caller is an
        # admin: only oauth2-proxy (UI) and the bootstrap may reach it.
        resources.ciliumNetworkPolicies.jellystat.spec = {
          endpointSelector.matchLabels."app.kubernetes.io/name" = "jellystat";
          ingress = [
            {fromEntities = ["host"];}
            {
              fromEndpoints = [
                {
                  matchLabels = {
                    "k8s:io.kubernetes.pod.namespace" = "identity";
                    "app.kubernetes.io/name" = "oauth2-proxy";
                  };
                }
                {matchLabels."batch.kubernetes.io/job-name" = "jellystat-bootstrap";}
                {matchLabels."app.kubernetes.io/name" = "media-e2e";}
              ];
              toPorts = lib.toList {
                ports = lib.toList {
                  port = "3000";
                  protocol = "TCP";
                };
              };
            }
          ];
        };
        bootstrap = {
          image = with pinned.images.curl; "${repository}:${tag}@${digest}";
          args = ["sh" "-c" bootstrap];
          secrets.jellyfin = "jellyfin-admin";
        };
      }
      (generated "jellystat-jwt")
      (generated "jellystat-admin")
    ];
  };
}
