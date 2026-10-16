{config, ...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "jitsi.${domain}";
    xmppPasswords = ["recorder" "jibri" "jicofo" "component" "jigasi" "jvb"];
    probe = {
      periodSeconds = 10;
      timeoutSeconds = 5;
      failureThreshold = 6;
    };
    startupProbe = handler:
      probe
      // handler
      // {
        failureThreshold = 60;
      };
    xmppRef = n: {
      secretKey = n;
      remoteRef.key = "jitsi-${n}";
      remoteRef.property = "password";
    };
  in {
    gatus.endpoints.jitsi = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302)"];
    };
    applications.jitsi = {
      namespace = "media";
      volsync.pvcs = {
        jibri.title = "jitsi-jitsi-meet-jibri";
        # The chart's StatefulSet claim (prosody-data-<pod>); "prosody-data" never existed, so this
        # source failed silently from 2026-06-25 (found by the docs/media-stack.md audit).
        prosody = {
          title = "prosody-data-jitsi-prosody-0";
        };
      };
      helm.releases.jitsi = {
        chart = pinned.charts.jitsi-meet;
        values = {
          enableAuth = true;
          enableGuests = false;
          publicURL = hostname;
          # Fixed dummies for every secret field the chart would otherwise
          # randAlphaNum (all six live in templates/*/xmpp-secret.yaml). Unset,
          # each render mints a fresh value, drifting the deployments'
          # checksum/secret annotation -> spurious diffs + pod restarts on every
          # sync. The rendered Secret data is blanked below; real credentials
          # arrive via ExternalSecrets, so these dummies never reach runtime.
          jicofo.xmpp.password = "nixidy-rendered-dummy";
          jicofo.xmpp.componentSecret = "nixidy-rendered-dummy";
          jvb.xmpp.password = "nixidy-rendered-dummy";
          jibri.xmpp.password = "nixidy-rendered-dummy";
          jibri.recorder.password = "nixidy-rendered-dummy";
          jigasi.xmpp.password = "nixidy-rendered-dummy";
          websockets.colibri.enabled = true;
          websockets.xmpp.enabled = true;
          jigasi.enabled = true;
          jibri = {
            enabled = true;
            singleUseMode = true;
            livestreaming = true;
            persistence.enabled = true;
            shm.enabled = true;
            shm.useHost = true;
          };
          jvb.publicIPs = ["192.168.50.254"];
          # Exporter sidecar over the bridge's colibri stats, plus the chart's ServiceMonitor.
          jvb.metrics = {
            enabled = true;
            image = with pinned.images.jitsi-meet-exporter; {
              inherit repository;
              tag = "${tag}@${digest}";
            };
          };
          # The chart sets externalTrafficPolicy on a ClusterIP Service, which the API rejects.
          jvb.service.externalTrafficPolicy = null;
          prosody.enabled = true;
          prosody.persistence.enabled = true;
          # The chart's probes have 1s timeouts and no startup gate; on sirver's slow disk prosody's
          # 10-config init (key and cert generation) takes ~4 min, so liveness killed it before it
          # listened. startupProbes (added below, the chart has no value for them) hold the others off.
          prosody.livenessProbe = probe;
          prosody.readinessProbe = probe;
          jicofo.livenessProbe = probe;
          jicofo.readinessProbe = probe;
          jvb.livenessProbe = probe;
          jvb.readinessProbe = probe;
          web.livenessProbe = probe;
          web.readinessProbe = probe;
          # The jitsi/* images below are public + digest-pinned; "Never" can't pull
          # them on a node that lacks them -> ErrImageNeverPull (jitsi never ran).
          image.pullPolicy = "IfNotPresent";
          jibri.image = with pinned.images.jitsi-jibri; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          jicofo.image = with pinned.images.jitsi-jicofo; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          jigasi.image = with pinned.images.jitsi-jigasi; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          jvb.image = with pinned.images.jitsi-jvb; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          web.image = with pinned.images.jitsi-web; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          prosody.image = with pinned.images.jitsi-prosody; {
            inherit repository;
            tag = "${tag}@${digest}";
          };
          jibri.resources.requests = {
            cpu = "65m";
            memory = "1072Mi";
          };
          jicofo.resources.requests = {
            cpu = "25m";
            memory = "1072Mi";
          };
          jigasi.resources.requests = {
            cpu = "90m";
            memory = "240Mi";
          };
          jvb.resources.requests = {
            cpu = "25m";
            memory = "336Mi";
          };
          web.resources.requests = {
            cpu = "25m";
            memory = "32Mi";
          };
          prosody.resources.requests = {
            cpu = "25m";
            memory = "48Mi";
          };
        };
      };
      resources = {
        # The chart's ServiceMonitor also selects on helm.sh/chart and app.kubernetes.io/version, labels
        # nixidy strips from the rendered Service, so it would match nothing.
        serviceMonitors.jitsi-jitsi-meet-jvb.spec = {
          selector.matchLabels = lib.mkForce {
            "app.kubernetes.io/component" = "jvb";
            "app.kubernetes.io/instance" = "jitsi";
            "app.kubernetes.io/name" = "jitsi-meet";
          };
          endpoints = lib.mkForce (lib.toList {
            port = "tcp-metrics";
            path = "/metrics";
            interval = "1m";
          });
        };
        # jigasi (SIP) and jibri (recording) are deferred: parked at 0 replicas, config kept.
        deployments.jitsi-jitsi-meet-jigasi.spec.replicas = lib.mkForce 0;
        deployments.jitsi-jitsi-meet-jibri.spec.replicas = lib.mkForce 0;
        statefulSets.jitsi-prosody.spec.template.spec.containers.prosody.startupProbe = startupProbe {
          httpGet = {
            path = "/http-bind";
            port = "bosh-insecure";
          };
        };
        deployments.jitsi-jitsi-meet-jicofo.spec.template.spec.containers.jitsi-meet.startupProbe = startupProbe {tcpSocket.port = 8888;};
        deployments.jitsi-jitsi-meet-jvb.spec.template.spec.containers.jitsi-meet.startupProbe = startupProbe {
          httpGet = {
            path = "/about/health";
            port = 8080;
          };
        };
        deployments.jitsi-jitsi-meet-web.spec.template.spec.containers.jitsi-meet.startupProbe = startupProbe {
          httpGet = {
            path = "/";
            port = 80;
          };
        };
        httpRoutes.jitsi-web.spec = {
          hostnames = [hostname];
          # Public rooms — exposed via external gateway, no oauth2-proxy.
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "jitsi-jitsi-meet-web";
              port = 80;
            };
          };
        };
        secrets = {
          jitsi-prosody-jibri.data = lib.mkForce {};
          jitsi-prosody-jicofo.data = lib.mkForce {};
          jitsi-prosody-jigasi.data = lib.mkForce {};
          jitsi-prosody-jvb.data = lib.mkForce {};
          jitsi-prosody.data = lib.mkForce {};
        };
        # Random once, never refreshed: the XMPP accounts are provisioned from
        # these values at first start.
        passwords = lib.genAttrs (map (n: "jitsi-${n}") xmppPasswords) (_: {
          spec = {
            length = 32;
            digits = 10;
            symbols = 0;
            noUpper = false;
            allowRepeat = true;
          };
        });
        externalSecrets =
          lib.genAttrs (map (n: "jitsi-${n}") xmppPasswords) (name: {
            spec = {
              refreshPolicy = "CreatedOnce";
              dataFrom = lib.toList {
                sourceRef.generatorRef = {
                  apiVersion = "generators.external-secrets.io/v1alpha1";
                  kind = "Password";
                  inherit name;
                };
              };
            };
          })
          // {
            jitsi-prosody-jibri.spec = {
              secretStoreRef.name = "kubernetes-media";
              secretStoreRef.kind = "ClusterSecretStore";
              data = [
                (xmppRef "recorder")
                (xmppRef "jibri")
              ];
              target.template.data = {
                JIBRI_RECORDER_PASSWORD = "{{ .recorder }}";
                JIBRI_RECORDER_USER = "recorder";
                JIBRI_XMPP_PASSWORD = "{{ .jibri }}";
                JIBRI_XMPP_USER = "jibri";
              };
            };
            jitsi-prosody-jicofo.spec = {
              secretStoreRef.name = "kubernetes-media";
              secretStoreRef.kind = "ClusterSecretStore";
              data = [
                (xmppRef "jicofo")
                (xmppRef "component")
              ];
              target.template.data = {
                JICOFO_AUTH_PASSWORD = "{{ .jicofo }}";
                JICOFO_AUTH_USER = "focus";
                JICOFO_COMPONENT_SECRET = "{{ .component }}";
              };
            };
            jitsi-prosody-jigasi.spec = {
              secretStoreRef.name = "kubernetes-media";
              secretStoreRef.kind = "ClusterSecretStore";
              data = lib.toList (xmppRef "jigasi");
              target.template.data = {
                JIGASI_XMPP_PASSWORD = "{{ .jigasi }}";
                JIGASI_XMPP_USER = "jigasi";
              };
            };
            jitsi-prosody-jvb.spec = {
              secretStoreRef.name = "kubernetes-media";
              secretStoreRef.kind = "ClusterSecretStore";
              data = lib.toList (xmppRef "jvb");
              target.template.data = {
                JVB_AUTH_PASSWORD = "{{ .jvb }}";
                JVB_AUTH_USER = "jvb";
              };
            };
          };
      };
    };
  };
}
