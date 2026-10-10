# Strong auth for the default realm: a passkey-first browser flow and the
# required actions that get tristan onto a passkey + TOTP.
#
# The operator has no flow CRD and a realm PUT never creates flows, so the flow
# is applied by keycloak-config-cli (declarative, reapplied on every sync).
# Per-user state can't be declarative (the operator re-PUTs users every 5 min,
# so requiredActions in the CR would re-prompt forever), so a kcadm step only
# adds what's missing.
{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  nixidy = {lib, ...}: let
    exec = authenticator: requirement: priority: {
      inherit authenticator requirement priority;
      authenticatorFlow = false;
      userSetupAllowed = false;
    };
    sub = flowAlias: requirement: priority: {
      inherit flowAlias requirement priority;
      authenticatorFlow = true;
      userSetupAllowed = false;
    };
    flow = alias: topLevel: description: authenticationExecutions: {
      inherit alias topLevel description authenticationExecutions;
      providerId = "basic-flow";
      builtIn = false;
    };
    # username -> passkey if registered, otherwise ("Try another way" too)
    # password + OTP or security key once either is configured.
    realm = {
      realm = "default";
      browserFlow = "browser-passkey";
      authenticationFlows = [
        (flow "browser-passkey" true "Passkey first, password + second factor fallback" [
          (exec "auth-cookie" "ALTERNATIVE" 10)
          (exec "identity-provider-redirector" "ALTERNATIVE" 20)
          (sub "browser-passkey forms" "ALTERNATIVE" 30)
        ])
        (flow "browser-passkey forms" false "Username, then a method" [
          (exec "auth-username-form" "REQUIRED" 10)
          (sub "browser-passkey method" "REQUIRED" 20)
        ])
        (flow "browser-passkey method" false "Passkey, or password + second factor" [
          (exec "webauthn-authenticator-passwordless" "ALTERNATIVE" 10)
          (sub "browser-passkey password" "ALTERNATIVE" 20)
        ])
        (flow "browser-passkey password" false "Password, then a configured second factor" [
          (exec "auth-password-form" "REQUIRED" 10)
          (sub "browser-passkey 2fa" "CONDITIONAL" 20)
        ])
        # Skipped until the user has OTP or a security key, so password-only
        # still works before enrollment.
        (flow "browser-passkey 2fa" false "OTP or security key, if configured" [
          (exec "conditional-user-configured" "REQUIRED" 10)
          (exec "auth-otp-form" "ALTERNATIVE" 20)
          (exec "webauthn-authenticator" "ALTERNATIVE" 30)
        ])
      ];
    };
    user = people.me;
    marker = "homelab.initial-password.${user}";
    script = ''
      set -euo pipefail
      export HOME=/tmp
      kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
      for i in $(seq 60); do
        kc config credentials --server "$KEYCLOAK_URL" --realm master \
          --user "$KEYCLOAK_USER" --password "$KEYCLOAK_PASSWORD" >/dev/null 2>&1 && break
        [ "$i" = 60 ] && { echo "keycloak admin login failed"; exit 1; }
        sleep 5
      done
      R=default
      U=$(kc get users -r $R -q username=${user} -q exact=true --fields id --format csv --noquotes)
      [ -n "$U" ] || { echo "user ${user} not found yet"; exit 1; }

      # One-time initial password (generated, in Bitwarden), temporary so the
      # first login replaces it. The realm attribute stops it ever repeating.
      if kc get realms/$R | grep -q '"${marker}"'; then
        echo "initial password already set once"
      else
        printf '{"type":"password","temporary":true,"value":"%s"}' "$(cat /secrets/initial/password)" > /tmp/pw.json
        kc update users/$U/reset-password -r $R -f /tmp/pw.json
        rm -f /tmp/pw.json
        kc update realms/$R --merge -s 'attributes."${marker}"='"$(date -u +%FT%TZ)"
        echo "set temporary initial password"
      fi

      # Prompt for whatever is missing: a passkey and TOTP. Keycloak drops each
      # action once done, and nothing is re-added after enrollment.
      norm() { tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd, -; }
      creds=$(kc get users/$U/credentials -r $R --fields type --format csv --noquotes)
      current=$(kc get users/$U -r $R --fields requiredActions | grep -o '"[A-Za-z_-]*"' | sed '/"requiredActions"/d' | tr '\n' ' ')
      want=$current
      grep -qx webauthn-passwordless <<<"$creds" || want="$want "'"webauthn-register-passwordless"'
      grep -qx otp <<<"$creds" || want="$want "'"CONFIGURE_TOTP"'
      want=$(norm <<<"$want")
      have=$(norm <<<"$current")
      if [ "$want" != "$have" ]; then
        kc update users/$U -r $R --merge -s "requiredActions=[$want]"
        echo "required actions: [$want]"
      else
        echo "required actions unchanged: [$have]"
      fi
    '';
    keycloakEnv = [
      {
        name = "KEYCLOAK_URL";
        value = "http://keycloak.identity.svc.cluster.local:8080";
      }
      {
        name = "KEYCLOAK_USER";
        valueFrom.secretKeyRef = {
          name = "keycloak";
          key = "KC_BOOTSTRAP_ADMIN_USERNAME";
        };
      }
      {
        name = "KEYCLOAK_PASSWORD";
        valueFrom.secretKeyRef = {
          name = "keycloak";
          key = "KC_BOOTSTRAP_ADMIN_PASSWORD";
        };
      }
    ];
    securityContext = {
      allowPrivilegeEscalation = false;
      readOnlyRootFilesystem = true;
      capabilities.drop = ["ALL"];
    };
  in {
    applications.keycloak.resources = {
      configMaps.keycloak-auth.data."realm-default.json" = builtins.toJSON realm;

      # Break-glass-free first login: random once, never refreshed, readable in
      # Bitwarden. Only ever applied once (see marker above).
      passwords.keycloak-initial-password.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      externalSecrets.keycloak-initial-password.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "keycloak-initial-password";
          };
        };
      };
      pushSecrets.keycloak-initial-password.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "keycloak-initial-password";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "keycloak/${user}/initial-password";
          };
        };
      };

      jobs.keycloak-auth = {
        metadata.annotations = {
          "argocd.argoproj.io/hook" = "PostSync";
          "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
        };
        spec = {
          backoffLimit = 6;
          activeDeadlineSeconds = 1200;
          template.spec = {
            restartPolicy = "OnFailure";
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            initContainers = lib.toList {
              name = "flows";
              image = "docker.io/adorsys/keycloak-config-cli:6.5.1-26.1.0@sha256:1b22dfaa9ae0c71f74b0342f9221a6510f272da5def683dbba26a98e6b1b1411";
              env =
                keycloakEnv
                ++ [
                  {
                    name = "KEYCLOAK_AVAILABILITYCHECK_ENABLED";
                    value = "true";
                  }
                  {
                    name = "KEYCLOAK_AVAILABILITYCHECK_TIMEOUT";
                    value = "300s";
                  }
                  {
                    name = "IMPORT_FILES_LOCATIONS";
                    value = "/config/*.json";
                  }
                  # Reapply every sync so drift (e.g. a rebound flow) is corrected.
                  {
                    name = "IMPORT_CACHE_ENABLED";
                    value = "false";
                  }
                  {
                    name = "JAVA_TOOL_OPTIONS";
                    value = "-Djava.io.tmpdir=/tmp";
                  }
                ];
              volumeMounts = [
                {
                  name = "config";
                  mountPath = "/config";
                  readOnly = true;
                }
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
              ];
              inherit securityContext;
            };
            containers = lib.toList {
              name = "users";
              image = "quay.io/keycloak/keycloak:26.1.5@sha256:be6a86215213145bfb4fb3e2b3ab982a806d00262655abdcf3ffa6a38d241c7c";
              command = ["/bin/bash" "-c" script];
              env = keycloakEnv;
              volumeMounts = [
                {
                  name = "initial";
                  mountPath = "/secrets/initial";
                  readOnly = true;
                }
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
              ];
              inherit securityContext;
            };
            volumes = [
              {
                name = "config";
                configMap.name = "keycloak-auth";
              }
              {
                name = "initial";
                secret.secretName = "keycloak-initial-password";
              }
              {
                name = "tmp";
                emptyDir = {};
              }
            ];
          };
        };
      };
    };
  };
}
