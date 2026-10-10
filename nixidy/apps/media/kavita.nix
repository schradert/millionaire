{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  # NOTE: Kavita does not support Postgres — it uses an embedded SQLite DB
  # backed up via volsync on the config PVC.
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "kavita.${domain}";
  in {
    gatus.endpoints.kavita = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    # Kavita native OIDC: the bootstrap job writes the settings (needs the client
    # secret, mirrored into media below). Callback paths are fixed by Kavita.
    # Logins link to an existing user by verified email (tristan -> the
    # bootstrapped admin). Kavita can only sync roles from a roles claim, which
    # also rewrites libraries on every login, so admin stays on that account.
    applications.keycloak.resources.keycloakClients.kavita.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "kavita";
        create = true;
      };
      definition = {
        clientId = "kavita";
        name = "Kavita";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/signin-oidc"];
        webOrigins = ["https://${hostname}"];
        attributes."post.logout.redirect.uris" = "https://${hostname}/signout-callback-oidc";
        # Kavita requests openid profile offline_access roles email.
        defaultClientScopes = ["openid" "profile" "email" "roles" "groups"];
        optionalClientScopes = ["offline_access"];
      };
    };
    applications.kavita = {
      namespace = "media";
      volsync.pvcs.kavita.title = "kavita";
      helm.releases.kavita = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.kavita.containers.kavita = {
            image = pinned.images.kavita;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            # First start after a schema bump runs migrations; the default 30s
            # startup budget kills it mid-migration every time.
            probes.startup = {
              enabled = true;
              spec.failureThreshold = 60;
            };
          };
          service.kavita.ports.http.port = 5000;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/kavita/config";}];
          };
          persistence.media-books = {
            type = "persistentVolumeClaim";
            existingClaim = "media-books";
            advancedMounts.kavita.kavita = [
              {
                path = "/media/books";
                readOnly = true;
              }
            ];
          };
          persistence.media-comics = {
            type = "persistentVolumeClaim";
            existingClaim = "media-comics";
            advancedMounts.kavita.kavita = [
              {
                path = "/media/comics";
                readOnly = true;
              }
            ];
          };
          # Native OIDC, no oauth2-proxy. OPDS clients (e-readers) use the same
          # route: Kavita enforces its per-user API key on /api/opds.
          route.kavita = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "kavita";
                port = 5000;
              };
            };
          };
        };
      };

      resources.externalSecrets.kavita-oidc.spec.data = lib.toList {
        secretKey = "client_secret";
        remoteRef.key = "kavita";
        remoteRef.property = "client-secret";
        sourceRef.storeRef.name = "kubernetes-identity";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
      resources.passwords.kavita-admin.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.kavita-admin.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "kavita-admin";
          };
        };
      };
      resources.pushSecrets.kavita-admin.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "kavita-admin";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "kavita/admin-password";
          };
        };
      };
      # Kavita registers its OIDC handler only at startup, so the job deletes the
      # kavita pod once after first configuring OIDC; it needs pod delete rights.
      resources.serviceAccounts.kavita-bootstrap = {};
      resources.roles.kavita-bootstrap.rules = lib.toList {
        apiGroups = [""];
        resources = ["pods"];
        verbs = ["get" "list" "delete"];
      };
      resources.roleBindings.kavita-bootstrap = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = "kavita-bootstrap";
        };
        subjects = lib.toList {
          kind = "ServiceAccount";
          name = "kavita-bootstrap";
          namespace = "media";
        };
      };
      # Idempotent post-sync bootstrap: first admin (first registered user is
      # admin), the Books/Comics libraries, and Keycloak OIDC in the server
      # settings (apps/app-bootstrap). Reruns after every sync: must stay a no-op.
      # Image: `image publish app-bootstrap` (modules/images.nix) -> Harbor.
      resources.jobs.kavita-bootstrap = {
        metadata.annotations = {
          "argocd.argoproj.io/hook" = "PostSync";
          "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
        };
        spec = {
          backoffLimit = 6;
          activeDeadlineSeconds = 1200;
          template.spec = {
            restartPolicy = "OnFailure";
            serviceAccountName = "kavita-bootstrap";
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = lib.toList {
              name = "bootstrap";
              image = with pinned.images.app-bootstrap-kavita; "${repository}:${tag}@${digest}";
              args = ["kavita"];
              env = [
                {
                  name = "KAVITA_URL";
                  value = "http://kavita.media.svc.cluster.local:5000";
                }
                {
                  name = "ADMIN_EMAIL";
                  value = people.my.profiles.personal.email;
                }
                {
                  name = "ADMIN_PASSWORD_FILE";
                  value = "/secrets/admin/password";
                }
                {
                  name = "OIDC_AUTHORITY";
                  value = "https://keycloak.${domain}/realms/default";
                }
                {
                  name = "OIDC_CLIENT_ID";
                  value = "kavita";
                }
                {
                  name = "OIDC_CLIENT_SECRET_FILE";
                  value = "/secrets/oidc/client_secret";
                }
              ];
              volumeMounts = [
                {
                  name = "admin";
                  mountPath = "/secrets/admin";
                  readOnly = true;
                }
                {
                  name = "oidc";
                  mountPath = "/secrets/oidc";
                  readOnly = true;
                }
              ];
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = ["ALL"];
              };
            };
            volumes = [
              {
                name = "admin";
                secret.secretName = "kavita-admin";
              }
              {
                name = "oidc";
                secret.secretName = "kavita-oidc";
              }
            ];
          };
        };
      };
    };
  };
}
