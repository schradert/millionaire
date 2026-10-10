{config, ...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "jitsi.${domain}";
    xmppPasswords = ["recorder" "jibri" "jicofo" "component" "jigasi" "jvb"];
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
        prosody.title = "prosody-data";
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
          prosody.enabled = true;
          prosody.persistence.enabled = true;
          # prosody's 10-config init takes >30s here; the chart's default probes
          # (no delay, 3 failures) kill it mid-init every time.
          prosody.livenessProbe = {
            httpGet = {
              path = "/http-bind";
              port = "bosh-insecure";
            };
            initialDelaySeconds = 120;
            periodSeconds = 10;
            failureThreshold = 12;
          };
          prosody.readinessProbe = {
            httpGet = {
              path = "/http-bind";
              port = "bosh-insecure";
            };
            initialDelaySeconds = 30;
            periodSeconds = 10;
          };
          # The jitsi/* images below are public + digest-pinned; "Never" can't pull
          # them on a node that lacks them -> ErrImageNeverPull (jitsi never ran).
          image.pullPolicy = "IfNotPresent";
          jibri.image = {
            repository = "jitsi/jibri";
            tag = "jibri-8.0-194-g71e6738-1@sha256:d757a5cb8a55d8e9afb9e53f27b558cade750eeeba89050435cc97af0aa5f902";
          };
          jicofo.image = {
            repository = "jitsi/jicofo";
            tag = "jicofo-1.0-1174-1@sha256:b4f9adfa4d752e87c82428aa7241a8a4e3aaafa9db370d57ba3c0e179d0d57da";
          };
          jigasi.image = {
            repository = "jitsi/jigasi";
            tag = "jigasi-1.1-407-g1e3a7ac-1@sha256:2f063da007903bacc756c79e751e189b339703f2f7a8e58492792e60c4984e72";
          };
          jvb.image = {
            repository = "jitsi/jvb";
            tag = "jvb-2.3-280-g159a678e5-1@sha256:27d74c778b7215c51267bc140006fc4fe19d06275c00dc87783eb0cbb888884f";
          };
          web.image = {
            repository = "jitsi/web";
            tag = "web-1.0.9126-1@sha256:2092fd409c0c9ec7f9325d88df1c8e8ee092a26e98931ae3954d4dc02f07de41";
          };
          prosody.image = {
            repository = "jitsi/prosody";
            tag = "prosody-13.0.4@sha256:51dd47542eda780cf51815404459c415a2af49b77385b6c5ba091e79001a3a81";
          };
        };
      };
      resources = {
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
