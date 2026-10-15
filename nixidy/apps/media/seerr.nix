{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "seerr.${domain}";
    # Single sign-on in front of Seerr. oauth2-proxy has already admitted a Keycloak `admin`
    # user; when the browser has no Seerr session this signs in as the Jellyfin admin account
    # (Seerr user 1, admin) and sets the session cookie, so the user lands signed in. A
    # session Seerr no longer accepts sends /login back through the same step.
    ssoConf = ''
      map $http_cookie $seerr_no_session { default 1; "~(^|;\s*)connect\.sid=" 0; }
      map $arg_next $seerr_next { default /; "~^/([^/\\\\]|$)" $arg_next; }
      server {
        listen 5056;
        absolute_redirect off;
        location = /_login {
          internal;
          proxy_pass http://127.0.0.1:5055/api/v1/auth/jellyfin;
          proxy_method POST;
          proxy_pass_request_body off;
          proxy_set_header Content-Type application/json;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_body '{"username":"admin","password":"{{ .password }}"}';
        }
        # `return` runs before the access phase, so the redirect is a named location
        # reached from try_files, after auth_request has made the session.
        location = /_sso {
          auth_request /_login;
          auth_request_set $seerr_cookie $upstream_http_set_cookie;
          try_files /_none @seerr_signed_in;
        }
        location @seerr_signed_in {
          add_header Set-Cookie $seerr_cookie always;
          return 302 $seerr_next;
        }
        location = /login { return 302 /_sso?next=/; }
        location / {
          if ($seerr_no_session) { return 302 /_sso?next=$uri; }
          proxy_pass http://127.0.0.1:5055;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto https;
          proxy_http_version 1.1;
        }
      }
    '';
  in {
    portal.apps.seerr.groups = ["admin"];
    gatus.endpoints.seerr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.seerr = {
      namespace = "media";
      # Seerr has no native OIDC in any release (v3.5.0 and develop; the OIDC pull
      # request #2715 is open and its preview image has no group-to-role mapping), so it
      # stays behind oauth2-proxy (admin) and the `sso` sidecar below signs the user in. Its
      # only admin path is the setup wizard's Jellyfin sign-in, which makes the
      # Jellyfin admin Seerr user 1. This job does that with the bootstrapped
      # Jellyfin `admin` account and tristan's email, enables all libraries and
      # finishes the wizard. Break-glass is that Jellyfin admin login
      # (Secret jellyfin-admin, Bitwarden jellyfin/admin-password); Seerr has no
      # separate admin password. Radarr and Sonarr are added as default servers.
      # Idempotent post-sync bootstrap (apps/app-bootstrap seerr, >= 0.7.0).
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-seerr) {
        image = with pinned.images.app-bootstrap-seerr; "${repository}:${tag}@${digest}";
        args = ["seerr"];
        env = {
          SEERR_URL = "http://seerr.media.svc.cluster.local:5055";
          JELLYFIN_HOST = "jellyfin.media.svc.cluster.local";
          JELLYFIN_PORT = "8096";
          JELLYFIN_ADMIN_USER = "admin";
          JELLYFIN_ADMIN_PASSWORD_FILE = "/secrets/jellyfin/password";
          ADMIN_EMAIL = people.my.profiles.personal.email;
          # Radarr/Sonarr as default servers (>= 0.15.0); the profiles are Recyclarr's.
          RADARR_API_KEY_FILE = "/secrets/radarr/apikey";
          SONARR_API_KEY_FILE = "/secrets/sonarr/apikey";
          # Default servers request 1080p; the separate 4K servers (>= 0.22.2) use Recyclarr's 2160p profiles.
          RADARR_PROFILE = "HD-1080p";
          SONARR_PROFILE = "WEB-1080p";
          RADARR_4K_PROFILE = "[SQP] SQP-1 WEB (2160p)";
          SONARR_4K_PROFILE = "WEB-2160p";
        };
        secrets = {
          jellyfin = "jellyfin-admin";
          radarr = "radarr-apikey";
          sonarr = "sonarr-apikey";
        };
      };
      volsync.pvcs.seerr.title = "seerr";
      helm.releases.seerr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          # The image runs as node (1000); the volume mounts root-owned.
          controllers.seerr.pod.securityContext = {
            fsGroup = 1000;
            fsGroupChangePolicy = "OnRootMismatch";
          };
          controllers.seerr.annotations."reloader.stakater.com/auto" = "true";
          controllers.seerr.containers.seerr = {
            image = pinned.images.seerr;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          controllers.seerr.containers.sso = {
            image = pinned.images.nginx;
            ports = lib.toList {
              name = "sso";
              containerPort = 5056;
            };
            # The default probes check the Service's first port, which is Seerr's.
            probes = lib.genAttrs ["liveness" "readiness" "startup"] (_: {
              enabled = true;
              custom = true;
              spec.tcpSocket.port = 5056;
            });
          };
          service.seerr.ports = {
            http.port = 5055;
            sso.port = 5056;
          };
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            advancedMounts.seerr.seerr = [{path = "/app/config";}];
          };
          persistence.sso = {
            type = "secret";
            name = "seerr-sso";
            advancedMounts.seerr.sso = lib.toList {
              path = "/etc/nginx/conf.d/default.conf";
              subPath = "default.conf";
              readOnly = true;
            };
          };
          route.seerr = {
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
      # The sidecar's config holds the Jellyfin admin password, so it is a Secret.
      resources.externalSecrets.seerr-sso.spec = {
        secretStoreRef.name = "kubernetes-media";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data."default.conf" = ssoConf;
        data = lib.toList {
          secretKey = "password";
          remoteRef.key = "jellyfin-admin";
          remoteRef.property = "password";
        };
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://seerr.media.svc.cluster.local:5056";
      namespace = "media";
    };
  };
}
