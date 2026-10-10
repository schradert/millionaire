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
