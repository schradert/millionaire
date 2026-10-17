{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "cal.${domain}";
in {
  nixidy = {
    charts,
    config,
    lib,
    pinned,
    ...
  }: let
    # One DAV user per declared Keycloak user in the `admin` or `family` group (docs/invite.md), as the
    # per-user Maloja does (nixidy/apps/media/scrobbling.nix). Keycloak decides who exists; each user gets a
    # generated password (Secret baikal-user-<user>, pushed to Bitwarden as baikal/<user>/password) and the
    # calendar `org`. `admin` stays the break-glass DAV user and is never one of these.
    declared = lib.concatMap (u: let
      d = u.spec.definition;
    in
      lib.optional (d.username != "admin" && lib.any (g: lib.elem g (d.groups or [])) ["family" "admin"]) d)
    (lib.attrValues config.applications.keycloak.resources.keycloakUsers);
    users = lib.sort (a: b: a.username < b.username) declared;
    secretOf = u: "baikal-user-${lib.replaceStrings ["_" "."] ["-" "-"] (lib.toLower u)}";
  in {
    gatus.endpoints.baikal = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.baikal = {
      namespace = "home";
      volsync.pvcs.baikal = {
        title = "baikal";
      };
      # Admin password (web admin and the DAV user `admin`): break-glass. Everyone else
      # (every admin and family member of Keycloak) has a DAV user of their own and a
      # password of its own, which their clients and their org-bridge use.
      generatedSecrets =
        {
          baikal = {
            key = "BAIKAL_ADMIN_PASSWORD";
            bitwarden = "baikal/admin-password";
          };
        }
        // lib.listToAttrs (map (u:
          lib.nameValuePair (secretOf u.username) {
            key = "password";
            bitwarden = "baikal/${u.username}/password";
          })
        users);

      helm.releases.baikal = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.baikal = {
            annotations."reloader.stakater.com/auto" = "true";
            # The image ignores BAIKAL_ADMIN_PASSWORD and leaves Baïkal to its web
            # installer. This does that install (idempotent, every start), keeps the
            # admin + DAV user `admin` password in sync with the Secret and creates a
            # DAV user with an `org` calendar for each Keycloak user.
            initContainers.install = {
              image = pinned.images.baikal;
              command = ["sh" "-ec" "php /bootstrap/install.php && chown -R 101:101 /var/www/baikal/config /var/www/baikal/Specific"];
              envFrom = [{secretRef.name = "baikal";}];
              # The DAV users: BAIKAL_USER_<n>, BAIKAL_EMAIL_<n> and BAIKAL_PASSWORD_<n> (baikal-install.php).
              env = lib.listToAttrs (lib.concatLists (lib.imap0 (n: u: [
                  (lib.nameValuePair "BAIKAL_USER_${toString n}" u.username)
                  (lib.nameValuePair "BAIKAL_EMAIL_${toString n}" (u.email or ""))
                  (lib.nameValuePair "BAIKAL_PASSWORD_${toString n}" {
                    valueFrom.secretKeyRef = {
                      name = secretOf u.username;
                      key = "password";
                    };
                  })
                ])
                users));
            };
            containers.baikal = {
              image = pinned.images.baikal;
              resources.requests = {
                cpu = "25m";
                memory = "80Mi";
              };
              envFrom = [{secretRef.name = "baikal";}];
              # The install initContainer chowns config/ and Specific/; the image's
              # own chown -R over all of /var/www/baikal outlived the startup probe.
              env.BAIKAL_SKIP_CHOWN = "true";
              ports = [
                {
                  name = "http";
                  containerPort = 80;
                }
              ];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup = {
                enabled = true;
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };

          service.baikal.ports.http.port = 80;

          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "256Mi";
            # config/ (baikal.yaml) lives on the same volume, so the install persists.
            advancedMounts.baikal = lib.genAttrs ["baikal" "install"] (_: [
              {path = "/var/www/baikal/Specific";}
              {
                path = "/var/www/baikal/config";
                subPath = "config";
              }
            ]);
          };
          configMaps.install.data."install.php" = builtins.readFile ./baikal-install.php;
          persistence.install = {
            type = "configMap";
            identifier = "install";
            advancedMounts.baikal.install = [{path = "/bootstrap";}];
          };

          # CalDAV/CardDAV clients can't pass oauth2-proxy; Baïkal's own Digest auth
          # protects these paths. The web UI stays behind oauth2-proxy.
          route.baikal-dav = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              matches = map (path: {
                path = {
                  type = "PathPrefix";
                  value = path;
                };
              }) ["/dav.php" "/.well-known/caldav" "/.well-known/carddav"];
              backendRefs = lib.toList {
                name = "baikal";
                port = 80;
              };
            };
          };
          route.baikal = {
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
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://baikal.home.svc.cluster.local:80";
      namespace = "home";
    };
  };
}
