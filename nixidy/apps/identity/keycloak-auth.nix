# Strong auth for the default realm: a passkey-first browser flow and the
# required actions that get tristan onto a passkey + TOTP.
#
# The operator has no flow CRD and a realm PUT never creates flows, so the flow
# is applied by keycloak-config-cli (declarative, reapplied on every sync).
# Per-user state can't be declarative (the operator re-PUTs users every 5 min,
# so requiredActions in the CR would re-prompt forever), so a kcadm step only
# adds what's missing.
#
# The same step assigns client scopes: the operator only sends
# defaultClientScopes/optionalClientScopes when it creates a client, and
# Keycloak ignores them on update. It adds whatever a keycloakClients entry
# lists that Keycloak lacks, and never removes anything. Service-account roles
# (`keycloak.serviceAccountRoles.<clientId>`, realm-management roles) are added the same way,
# and for a client listed there any other realm-management role is removed: the list is exact.
# Fine-grained admin permissions (v2, `keycloak.groupAdmins.<clientId>`): the client's service account (a user policy)
# gets the listed scopes on named subgroups of a group, so it can create, change and delete only users
# that are members of those, whatever realm-management roles it has.
{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  nixidy = {
    config,
    lib,
    pinned,
    ...
  }: let
    clientScopes = lib.concatStrings (lib.mapAttrsToList (_: c: let
      d = c.spec.definition;
      line = kind: names: lib.optionalString (names != []) "ensure_scopes ${d.clientId} ${kind} ${lib.concatStringsSep " " names}\n";
    in
      line "default" (d.defaultClientScopes or []) + line "optional" (d.optionalClientScopes or []))
    config.applications.keycloak.resources.keycloakClients);
    groupAttrs = lib.concatStrings (lib.mapAttrsToList (_: g: let
      d = g.spec.definition;
    in
      lib.optionalString ((d.attributes or {}) != {}) "ensure_group_attrs ${lib.escapeShellArg d.name} ${lib.escapeShellArg (builtins.toJSON d.attributes)}\n")
    config.applications.keycloak.resources.keycloakGroups);
    serviceRoles = lib.concatStrings (lib.mapAttrsToList (client: roles: "ensure_service_roles ${client} ${lib.concatStringsSep " " roles}\n") config.keycloak.serviceAccountRoles);
    groupAdmins = lib.concatStrings (lib.mapAttrsToList (client: a: let
      subs = lib.concatStringsSep " " (lib.attrNames a.subGroups);
      attrLines = lib.concatStrings (lib.mapAttrsToList (n: attrs: "ensure_subgroup ${lib.escapeShellArg a.group} ${lib.escapeShellArg n} ${lib.escapeShellArg (builtins.toJSON attrs)}\n") a.subGroups);
    in "${attrLines}ensure_group_admin ${client} ${lib.escapeShellArg a.group} ${lib.escapeShellArg (lib.concatStringsSep " " a.scopes)} ${subs}\n")
    config.keycloak.groupAdmins);
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

      scopes=$(kc get client-scopes -r $R --fields name,id --format csv --noquotes)
      ensure_scopes() {
        local client=$1 kind=$2 cid have other n sid
        shift 2
        cid=$(kc get clients -r $R -q clientId="$client" -q exact=true --fields id --format csv --noquotes)
        [ -n "$cid" ] || { echo "client $client not created yet"; return 0; }
        have=$(kc get "clients/$cid/default-client-scopes" -r $R --fields name --format csv --noquotes)
        other=$(kc get "clients/$cid/optional-client-scopes" -r $R --fields name --format csv --noquotes)
        for n in "$@"; do
          grep -qx "$n" <<<"$have"$'\n'"$other" && continue
          sid=$(while IFS=, read -r name id; do if [ "$name" = "$n" ]; then echo "$id"; fi; done <<<"$scopes")
          [ -n "$sid" ] || continue # e.g. "openid" is implicit, not a scope
          kc update "clients/$cid/$kind-client-scopes/$sid" -r $R -n
          echo "client $client: added $kind scope $n"
        done
      }
      ${clientScopes}
      # Realm-management roles for a client's service account, exactly the listed set (the account exists once the
      # operator has created the client with serviceAccountsEnabled; until then the Job fails
      # and its backoffLimit retries, so the roles are never silently skipped).
      ensure_service_roles() {
        local client=$1 r
        shift
        kc get users -r $R -q username="service-account-$client" -q exact=true --fields id --format csv --noquotes | grep -q . \
          || { echo "service account of $client not created yet"; exit 1; }
        for r in "$@"; do
          kc add-roles -r $R --uusername "service-account-$client" --cclientid realm-management --rolename "$r"
        done
        for r in $(kc get-roles -r $R --uusername "service-account-$client" --cclientid realm-management --fields name --format csv --noquotes); do
          case " $* " in
            *" $r "*) ;;
            *)
              kc remove-roles -r $R --uusername "service-account-$client" --cclientid realm-management --rolename "$r"
              echo "service account of $client: removed role $r"
              ;;
          esac
        done
        echo "service account of $client: roles $*"
      }
      ${serviceRoles}
      group_id() {
        kc get groups -r $R -q search="$1" -q exact=true --fields id,name --format csv --noquotes | while IFS=, read -r id n; do if [ "$n" = "$1" ]; then echo "$id"; fi; done
      }
      child_id() {
        kc get "groups/$1/children" -r $R --fields id,name --format csv --noquotes | while IFS=, read -r id n; do if [ "$n" = "$2" ]; then echo "$id"; fi; done
      }
      # A subgroup of a top-level group, with attributes (a copy of a real group's, so apps map it the same).
      ensure_subgroup() {
        local parent=$1 name=$2 attrs=$3 pid sid
        pid=$(group_id "$parent")
        [ -n "$pid" ] || { echo "group $parent not created yet"; return 0; }
        sid=$(child_id "$pid" "$name")
        [ -n "$sid" ] || sid=$(kc create "groups/$pid/children" -r $R -s name="$name" -i)
        kc update "groups/$sid" -r $R --merge -s "attributes=$attrs"
        echo "group $parent/$name: attributes $attrs"
      }
      policy_id() {
        kc get "$1/policy" -r $R -q name="$2" --fields id,name --format csv --noquotes | while IFS=, read -r id name; do if [ "$name" = "$2" ]; then echo "$id"; fi; done
      }
      # A scope permission on groups (name, policy, scopes, comma-separated group ids), replaced when it differs.
      ensure_permission() {
        local base=$1 name=$2 policy=$3 want=$4 resources=$5 perm have have_pol have_res id n
        perm=$(kc get "$base/permission/scope" -r $R -q name="$name" --fields id,name --format csv --noquotes | while IFS=, read -r id n; do if [ "$n" = "$name" ]; then echo "$id"; fi; done)
        if [ -n "$perm" ]; then
          have=$(kc get "$base/permission/scope/$perm/scopes" -r $R --fields name --format csv --noquotes | sort | paste -sd, -)
          have_res=$(kc get "$base/permission/scope/$perm/resources" -r $R --fields name --format csv --noquotes | sort | paste -sd, -)
          have_pol=$(kc get "$base/permission/scope/$perm/associatedPolicies" -r $R --fields name --format csv --noquotes | sort | paste -sd, -)
          if [ "$have" = "$want" ] && [ "$have_res" = "$resources" ] && [ "$have_pol" = "$policy" ]; then
            echo "permission $name unchanged"
            return 0
          fi
          kc delete "$base/permission/scope/$perm" -r $R
        fi
        kc create "$base/permission/scope" -r $R -s name="$name" -s resourceType=Groups \
          -s "resources=[\"$(sed 's/,/","/g' <<<"$resources")\"]" \
          -s "scopes=[\"$(sed 's/,/","/g' <<<"$want")\"]" \
          -s "policies=[\"$policy\"]"
        echo "permission $name: [$want] on [$resources]"
      }
      # A user policy for the client's service account and permissions over the listed subgroups. A user policy, not a
      # client one: a user search is partially evaluated in SQL and only sees user policies, so with a client policy
      # `view-members` lists nobody. The parent group needs `view` too: without it creating a user in a subgroup is
      # refused while the subgroups are empty. Needs adminPermissionsEnabled on the realm, so the Job retries until it is on.
      ensure_group_admin() {
        local client=$1 parent=$2 scopes=$3 ap cid sa pid base resources n id
        shift 3
        ap=$(kc get clients -r $R -q clientId=admin-permissions --fields id --format csv --noquotes)
        [ -n "$ap" ] || { echo "admin permissions not enabled yet"; exit 1; }
        cid=$(kc get clients -r $R -q clientId="$client" -q exact=true --fields id --format csv --noquotes)
        [ -n "$cid" ] || { echo "client $client not created yet"; exit 1; }
        sa=$(kc get users -r $R -q username="service-account-$client" -q exact=true --fields id --format csv --noquotes)
        [ -n "$sa" ] || { echo "service account of $client not created yet"; exit 1; }
        pid=$(group_id "$parent")
        [ -n "$pid" ] || { echo "group $parent not created yet"; exit 1; }
        resources=""
        for n in "$@"; do
          id=$(child_id "$pid" "$n")
          [ -n "$id" ] || { echo "group $parent/$n not created yet"; exit 1; }
          resources="$resources$id"$'\n'
        done
        resources=$(sed '/^$/d' <<<"$resources" | sort | paste -sd, -)
        base="clients/$ap/authz/resource-server"
        if [ -z "$(policy_id "$base" "$client-user")" ]; then
          kc create "$base/policy/user" -r $R -s name="$client-user" -s type=user -s logic=POSITIVE -s "users=[\"$sa\"]"
          echo "policy $client-user created"
        fi
        ensure_permission "$base" "$client-$parent" "$client-user" "$(tr ' ' '\n' <<<"$scopes" | sort | paste -sd, -)" "$resources"
        ensure_permission "$base" "$client-$parent-parent" "$client-user" view "$pid"
      }
      ${groupAdmins}
      # Group attributes (e.g. immich_role, abs_group): the operator reports the
      # group synchronized but never applies them, so set what a keycloakGroups
      # entry declares.
      ensure_group_attrs() {
        local name=$1 want=$2 gid
        gid=$(kc get groups -r $R -q search="$name" -q exact=true --fields id,name --format csv --noquotes | while IFS=, read -r id n; do if [ "$n" = "$name" ]; then echo "$id"; fi; done)
        [ -n "$gid" ] || { echo "group $name not created yet"; return 0; }
        kc update "groups/$gid" -r $R --merge -s "attributes=$want"
        echo "group $name: attributes $want"
      }
      ${groupAttrs}
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
    options.keycloak.groupAdmins = lib.mkOption {
      description = "Fine-grained admin permissions by clientId: scopes on subgroups (name -> group attributes) of a top-level group";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          group = lib.mkOption {type = lib.types.str;};
          subGroups = lib.mkOption {type = lib.types.attrsOf lib.types.attrs;};
          scopes = lib.mkOption {type = lib.types.listOf lib.types.str;};
        };
      });
      default = {};
    };
    options.keycloak.serviceAccountRoles = lib.mkOption {
      description = "Realm-management roles for a Keycloak client's service account, by clientId";
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
    };
    config.applications.keycloak.resources = {
      # The script lives here too: ArgoCD doesn't diff hook Jobs, so a change
      # only triggers a sync (and so the PostSync job) via a regular resource.
      configMaps.keycloak-auth.data = {
        "realm-default.json" = builtins.toJSON realm;
        "users.sh" = script;
      };

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
              image = with pinned.images.keycloak-config-cli; "${repository}:${tag}@${digest}";
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
              image = with pinned.images.keycloak; "${repository}:${tag}@${digest}";
              command = ["/bin/bash" "/config/users.sh"];
              env = keycloakEnv;
              volumeMounts = [
                {
                  name = "config";
                  mountPath = "/config";
                  readOnly = true;
                }
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
