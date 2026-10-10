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
    hostname = "audiobookshelf.${domain}";
    # Stay behind oauth2-proxy until the bootstrap image is pinned: an
    # uninitialised server lets anyone claim root.
    bootstrapped = pinned.images ? app-bootstrap-audiobookshelf;
  in {
    gatus.endpoints.audiobookshelf = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Native OIDC, no oauth2-proxy. The bootstrap job writes the auth settings and
    # creates the root user as tristan; logins match that user by username, and the
    # `groups` claim (admin/user/guest) maps roles (root is never downgraded).
    # Redirect paths are fixed by ABS; audiobookshelf://oauth is the mobile app's
    # deep link, which ABS itself hops to after /auth/openid/mobile-redirect.
    applications.keycloak.resources.keycloakClients.audiobookshelf.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "audiobookshelf";
        create = true;
      };
      definition = {
        clientId = "audiobookshelf";
        name = "Audiobookshelf";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = [
          "https://${hostname}/auth/openid/callback"
          "https://${hostname}/auth/openid/mobile-redirect"
          "audiobookshelf://oauth"
        ];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.audiobookshelf = {
      namespace = "media";
      generatedSecrets.audiobookshelf-admin = {
        key = "password";
        bitwarden = "audiobookshelf/admin-password";
      };
      resources.externalSecrets.audiobookshelf-oidc.spec.data = lib.toList {
        secretKey = "client_secret";
        remoteRef.key = "audiobookshelf";
        remoteRef.property = "client-secret";
        sourceRef.storeRef.name = "kubernetes-identity";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
      # Idempotent post-sync bootstrap (apps/app-bootstrap audiobookshelf, >= 0.4.0):
      # root user, Audiobooks/Podcasts libraries, Keycloak OIDC auth settings.
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-audiobookshelf; "${repository}:${tag}@${digest}";
        args = ["audiobookshelf"];
        env = {
          AUDIOBOOKSHELF_URL = "http://audiobookshelf.media.svc.cluster.local:13378";
          ADMIN_USER = people.me;
          ADMIN_PASSWORD_FILE = "/secrets/admin/password";
          OIDC_AUTHORITY = "https://keycloak.${domain}/realms/default";
          OIDC_CLIENT_ID = "audiobookshelf";
          OIDC_CLIENT_SECRET_FILE = "/secrets/oidc/client_secret";
        };
        secrets = {
          admin = "audiobookshelf-admin";
          oidc = "audiobookshelf-oidc";
        };
      };
      volsync.pvcs.audiobookshelf = {
        title = "audiobookshelf-config";
        restore = false;
      };
      volsync.pvcs.audiobookshelf-metadata = {
        title = "audiobookshelf-metadata";
        restore = false;
      };
      helm.releases.audiobookshelf = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.audiobookshelf.containers.audiobookshelf = {
            image = pinned.images.audiobookshelf;
            # The image listens on :80 unless told otherwise.
            env.PORT = "13378";
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.audiobookshelf.ports.http.port = 13378;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/config";}];
          };
          persistence.metadata = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/metadata";}];
          };
          persistence.media-audiobooks = {
            type = "persistentVolumeClaim";
            existingClaim = "media-audiobooks";
            advancedMounts.audiobookshelf.audiobookshelf = [{path = "/media/audiobooks";}];
          };
          persistence.media-podcasts = {
            type = "persistentVolumeClaim";
            existingClaim = "media-podcasts";
            advancedMounts.audiobookshelf.audiobookshelf = [{path = "/media/podcasts";}];
          };
          route.audiobookshelf = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList (
                if bootstrapped
                then {
                  name = "audiobookshelf";
                  port = 13378;
                }
                else {
                  name = "oauth2-proxy";
                  namespace = "identity";
                  port = 4180;
                }
              );
            };
          };
        };
      };
    };
    oauth2Proxy.upstreams = lib.mkIf (!bootstrapped) {
      ${hostname} = {
        url = "http://audiobookshelf.media.svc.cluster.local:13378";
        namespace = "media";
      };
    };
  };
}
