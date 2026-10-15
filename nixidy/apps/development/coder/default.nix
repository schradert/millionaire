# Coder: cloud development workspaces (docs/dev-workspaces.md), at
# https://coder.<domain> on the internal Gateway (tailnet only).
#
# - Login through Keycloak (client `coder`). Coder does its own auth (the CLI and
#   the workspace agents need its API), so the route is not behind oauth2-proxy.
# - The bootstrap Job creates the first owner `admin` (generated password, in
#   Bitwarden at coder/admin-password) and tristan as an OIDC owner; his first
#   Keycloak login links to that account by email.
# - Workspaces are pods in namespace `workspaces`; Coder's ServiceAccount has a
#   Role only there (the chart's workspaceNamespaces).
# - Agents and the CLI hold long-lived WebSockets (DERP, tunnels), so the route
#   has no request timeout and DERP is forced over WebSockets.
# - Templates as code: each ./templates/<name>/ becomes a ConfigMap and the
#   bootstrap Job pushes it with `variables` as Terraform variables. A version
#   is named after the hash of its files and variables and pushed only once.
{config, ...}: let
  inherit (config.canivete.meta) domain people;
  hostname = "coder.${domain}";
  workspaces = "workspaces";
in {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    image = pinned.images.coder;
    imageRef = "${image.repository}:${image.tag}@${image.digest}";
    labels = {
      "app.kubernetes.io/instance" = "coder";
      "app.kubernetes.io/name" = "coder";
    };
    fromSecret = name: key: {valueFrom.secretKeyRef = {inherit name key;};};
    esc = lib.escapeShellArg;

    templatesDir = ./templates;
    templates = lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir templatesDir));
    files = name: lib.attrNames (lib.filterAttrs (_: t: t == "regular") (builtins.readDir (templatesDir + "/${name}")));
    contents = name: lib.genAttrs (files name) (f: builtins.readFile (templatesDir + "/${name}/${f}"));
    variables.devenv.image = with pinned.images.workspace; "${repository}:${tag}@${digest}";
    meta.devenv = {
      display = "devenv project";
      description = "One repository with its devenv, a persistent home and Nix store, Claude Code and opencode.";
      icon = "/emojis/2744.png";
    };
    version = name:
      builtins.substring 0 12 (builtins.hashString "sha256" (builtins.toJSON {
        files = contents name;
        variables = variables.${name} or {};
      }));
    # The variables go in a YAML file: `--variable` splits values on commas.
    push = name: let
      vars = "/tmp/variables-${name}.yaml";
      m = meta.${name};
      v = version name;
    in ''
      mkdir -p /tmp/templates/${name}
      ${lib.concatMapStringsSep "\n" (f: "cp -L ${esc "/templates/${name}/${f}"} ${esc "/tmp/templates/${name}/${f}"}") (files name)}
      : > ${vars}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: val: "echo ${esc "${k}: ${builtins.toJSON val}"} >> ${vars}") (variables.${name} or {}))}
      if coder templates versions list ${name} -o json 2>/dev/null | grep -qF '"${v}"'; then
        echo "${name}: ${v} already pushed"
      else
        coder templates push ${name} --directory /tmp/templates/${name} --name ${v} \
          --variables-file ${vars} --message ${esc "nixidy ${v}"} --yes
      fi
      coder templates edit ${name} --display-name ${esc m.display} --description ${esc m.description} \
        --icon ${esc m.icon} --default-ttl 8h --activity-bump 1h --yes
    '';
    bootstrap = ''
      url=http://coder.development.svc.cluster.local
      until curl -sf "$url/healthz" >/dev/null; do echo "waiting for coderd"; sleep 5; done
      if [ "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/v2/users/first")" = 404 ]; then
        coder login "$url" --first-user-username admin --first-user-email "$ADMIN_EMAIL" \
          --first-user-password "$ADMIN_PASSWORD" --first-user-full-name Admin --first-user-trial=false
      fi
      CODER_SESSION_TOKEN=$(curl -sf -X POST "$url/api/v2/users/login" -H 'Content-Type: application/json' \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" | sed -n 's/.*"session_token":"\([^"]*\)".*/\1/p')
      test -n "$CODER_SESSION_TOKEN"
      export CODER_URL=$url CODER_SESSION_TOKEN
      if ! coder users show "$USER_NAME" >/dev/null 2>&1; then
        coder users create --username "$USER_NAME" --email "$USER_EMAIL" --login-type oidc
      fi
      coder users edit-roles "$USER_NAME" --roles owner --yes
      # A user who has not logged in yet is dormant, and its workspaces' agents get 401.
      if coder users show "$USER_NAME" -o json | grep -q '"status": *"dormant"'; then
        coder users activate "$USER_NAME" <<<yes
      fi
      ${lib.concatMapStringsSep "\n" push templates}
    '';
  in {
    gatus.endpoints.coder = {
      url = "https://${hostname}/healthz";
      group = "internal";
    };
    portal.apps.coder.description = "Cloud development workspaces";

    applications.keycloak.resources.keycloakClients.coder.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "coder";
        create = true;
      };
      definition = {
        clientId = "coder";
        name = "Coder";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/api/v2/users/oidc/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };

    applications.namespaces.resources.namespaces.${workspaces} = {};

    applications.coder = {
      namespace = "development";
      postgres.enable = true;
      generatedSecrets.coder-admin = {
        key = "password";
        length = 32;
        bitwarden = "coder/admin-password";
      };
      helm.releases.coder = {
        chart = pinned.charts.coder;
        values.coder = {
          image = {
            repo = image.repository;
            tag = "${image.tag}@${image.digest}";
          };
          service.type = "ClusterIP";
          podAnnotations."reloader.stakater.com/auto" = "true";
          serviceAccount = {
            workspacePerms = false;
            workspaceNamespaces = lib.toList {
              name = workspaces;
              workspacePerms = true;
              enableDeployments = true;
            };
          };
          resources = {
            requests = {
              cpu = "250m";
              memory = "512Mi";
            };
            limits.memory = "2Gi";
          };
          env =
            lib.mapAttrsToList (name: value: {inherit name value;}) {
              CODER_ACCESS_URL = "https://${hostname}";
              CODER_OIDC_ISSUER_URL = "https://keycloak.${domain}/realms/default";
              CODER_OIDC_CLIENT_ID = "coder";
              CODER_OIDC_SCOPES = "openid,profile,email,groups";
              CODER_OIDC_EMAIL_FIELD = "email";
              CODER_OIDC_USERNAME_FIELD = "preferred_username";
              CODER_OIDC_SIGN_IN_TEXT = "Login with Keycloak";
              # Keycloak decides who exists; admin-created users may lack email_verified.
              CODER_OIDC_IGNORE_EMAIL_VERIFIED = "true";
              CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE = "false";
              CODER_DERP_FORCE_WEBSOCKETS = "true";
              CODER_SECURE_AUTH_COOKIE = "true";
              CODER_PROXY_TRUSTED_HEADERS = "X-Forwarded-For";
              CODER_PROXY_TRUSTED_ORIGINS = "10.0.0.0/8,192.168.50.0/24";
              CODER_PROMETHEUS_ENABLE = "true";
              CODER_PROMETHEUS_ADDRESS = "0.0.0.0:2112";
              CODER_PROMETHEUS_COLLECT_AGENT_STATS = "true";
              CODER_TELEMETRY_ENABLE = "false";
              CODER_UPDATE_CHECK = "false";
            }
            ++ [
              ({name = "CODER_PG_CONNECTION_URL";} // fromSecret "coder-app" "uri")
              ({name = "CODER_OIDC_CLIENT_SECRET";} // fromSecret "coder-oidc" "client-secret")
            ];
        };
      };

      resources = {
        externalSecrets.coder-oidc.spec = {
          secretStoreRef.name = "kubernetes-identity";
          secretStoreRef.kind = "ClusterSecretStore";
          target.template.data.client-secret = "{{ .oidc_secret }}";
          data = lib.toList {
            secretKey = "oidc_secret";
            remoteRef.key = "coder";
            remoteRef.property = "client-secret";
          };
        };

        services.coder-metrics = {
          metadata.labels."app.kubernetes.io/component" = "metrics";
          spec = {
            selector = labels;
            ports = lib.toList {
              name = "metrics";
              port = 2112;
              targetPort = 2112;
            };
          };
        };
        serviceMonitors.coder.spec = {
          selector.matchLabels = labels // {"app.kubernetes.io/component" = "metrics";};
          endpoints = lib.toList {
            port = "metrics";
            interval = "1m";
          };
        };

        httpRoutes.coder.spec = {
          hostnames = [hostname];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            backendRefs = lib.toList {
              name = "coder";
              port = 80;
            };
            timeouts.request = "0s";
          };
        };

        configMaps = lib.genAttrs (map (n: "coder-template-${n}") templates) (cm: {
          data = contents (lib.removePrefix "coder-template-" cm);
        });

        # Runs once per change of its spec (the name is its hash), after coderd is up.
        jobs."coder-bootstrap-${builtins.substring 0 8 (builtins.hashString "sha256" (bootstrap + imageRef))}" = {
          metadata.annotations."argocd.argoproj.io/sync-wave" = "5";
          spec = {
            backoffLimit = 6;
            activeDeadlineSeconds = 1200;
            template.spec = {
              restartPolicy = "OnFailure";
              automountServiceAccountToken = false;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 1000;
                runAsGroup = 1000;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = lib.toList {
                name = "bootstrap";
                image = imageRef;
                command = ["/bin/bash" "-euo" "pipefail" "-c" bootstrap];
                env = [
                  {
                    name = "HOME";
                    value = "/tmp";
                  }
                  {
                    name = "ADMIN_EMAIL";
                    value = "admin@${domain}";
                  }
                  {
                    name = "USER_NAME";
                    value = people.me;
                  }
                  {
                    name = "USER_EMAIL";
                    value = people.my.profiles.personal.email;
                  }
                  ({name = "ADMIN_PASSWORD";} // fromSecret "coder-admin" "password")
                ];
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = ["ALL"];
                };
                resources = {
                  requests = {
                    cpu = "50m";
                    memory = "64Mi";
                  };
                  limits.memory = "256Mi";
                };
                volumeMounts =
                  [
                    {
                      name = "tmp";
                      mountPath = "/tmp";
                    }
                  ]
                  ++ map (n: {
                    name = "template-${n}";
                    mountPath = "/templates/${n}";
                    readOnly = true;
                  })
                  templates;
              };
              volumes =
                [
                  {
                    name = "tmp";
                    emptyDir = {};
                  }
                ]
                ++ map (n: {
                  name = "template-${n}";
                  configMap.name = "coder-template-${n}";
                })
                templates;
            };
          };
        };
      };
    };

    # Workspace pods: capped per namespace. Nothing connects in (agents dial
    # coderd), so ingress is default-deny without an intra-namespace allowance.
    applications.${workspaces} = {
      namespace = workspaces;
      resources = {
        resourceQuotas.workspaces.spec.hard = {
          "requests.cpu" = "24";
          "requests.memory" = "64Gi";
          "limits.memory" = "96Gi";
          "requests.storage" = "1Ti";
          "requests.nvidia.com/gpu" = "1";
          persistentvolumeclaims = "40";
          "services.loadbalancers" = "0";
        };
        limitRanges.defaults.spec.limits = lib.toList {
          type = "Container";
          default.memory = "1Gi";
          defaultRequest = {
            cpu = "100m";
            memory = "128Mi";
          };
        };
      };
    };
    netpol.namespaces.${workspaces}.enforce = true;
    # Agents in workspaces call Bifrost in-cluster (no key; the public route needs Keycloak).
    netpol.namespaces.ai.extraIngress = lib.toList {
      fromEndpoints = lib.toList {matchLabels."k8s:io.kubernetes.pod.namespace" = workspaces;};
      toPorts = lib.toList {
        ports = lib.toList {
          port = "8000";
          protocol = "TCP";
        };
      };
    };
  };
}
