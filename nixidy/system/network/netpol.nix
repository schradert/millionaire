# Default-deny ingress per namespace, with a fixed baseline and per-app allows.
#
# `netpol.namespaces.<ns>.enforce = true` renders one CiliumClusterwideNetworkPolicy that
# selects every pod in the namespace (Cilium denies whatever no rule allows once a policy
# selects an endpoint) and allows only:
#   - kubelet/node probes and admission webhook calls (host, remote-node, kube-apiserver)
#   - the Gateway's envoy (`ingress` entity), for Services exposed through an HTTPRoute
#   - Prometheus and Gatus from `observability`
#   - oauth2-proxy, on exactly the ports its upstreams in this namespace use
#   - the namespace's own pods, only with `intraNamespace = true`
#   - whatever `extraIngress` adds (cross-namespace callers, external ports)
# `cnpg` / `dragonfly` add a second policy for the operator-managed database pods: the operators
# (in `storage`) keep long-lived connections that a flow capture never sees, so they are derived
# from how the operators work (CNPG instance manager :8000 and PostgreSQL :5432; Dragonfly :6379).
# Apps with their own ingress policy (`ciliumNetworkPolicies` or `networkPolicies`: navidrome,
# qbittorrent, rclone, ...) are excluded from the selector: Cilium policies are additive, so a namespace-wide allow would otherwise widen
# their stricter rules. They must allow `host` themselves.
# Egress is deliberately not restricted here: apps reach arbitrary external APIs and the
# Gateway VIP, so an egress allowlist would be wide enough to add no isolation.
# Rollout is one namespace at a time (flip `enforce`), after replaying the namespace's observed
# Hubble flows against the rendered rules.
{...}: {
  nixidy = {
    config,
    lib,
    ...
  }: let
    cfg = config.netpol;
    nsKey = "k8s:io.kubernetes.pod.namespace";
    enforced = lib.filterAttrs (_: ns: ns.enforce) cfg.namespaces;

    # `app.kubernetes.io/name` of every app in `ns` that carries its own ingress policy
    # (a CiliumNetworkPolicy, or a Kubernetes NetworkPolicy that covers Ingress).
    strictApps = ns: let
      apps = lib.filterAttrs (name: app: name != "netpol" && app.namespace == ns) config.applications;
      nameIn = labels:
        if labels == null
        then null
        else labels."app.kubernetes.io/name" or null;
      ciliumNames = app: map (p: nameIn p.spec.endpointSelector.matchLabels) (lib.attrValues app.resources.ciliumNetworkPolicies);
      k8sNames = app:
        map (p: nameIn p.spec.podSelector.matchLabels) (lib.filter (p: p.spec.policyTypes == null || lib.elem "Ingress" p.spec.policyTypes) (lib.attrValues app.resources.networkPolicies));
    in
      lib.unique (lib.filter (n: n != null) (lib.concatMap (app: ciliumNames app ++ k8sNames app) (lib.attrValues apps)));

    # oauth2-proxy talks to its upstreams from identity/oauth2-proxy; derive the ports per namespace.
    upstreamPorts = ns: let
      ups = lib.filter (u: u.namespace == ns) (lib.attrValues config.oauth2Proxy.upstreams);
      portOf = u: let
        m = builtins.match "https?://[^/:]+(:([0-9]+))?.*" u.url;
      in
        if m == null
        then null
        else if builtins.elemAt m 1 != null
        then builtins.elemAt m 1
        else if lib.hasPrefix "https" u.url
        then "443"
        else "80";
    in
      lib.unique (lib.filter (p: p != null) (map portOf ups));

    operatorPolicy = ns: selector: operator: ports: {
      description = "Operator access to the database pods in ${ns} (nixidy/system/network/netpol.nix)";
      endpointSelector.matchExpressions = [
        {
          key = nsKey;
          operator = "In";
          values = [ns];
        }
        selector
      ];
      ingress = lib.toList {
        fromEndpoints = [
          {
            matchLabels = {
              ${nsKey} = "storage";
              "app.kubernetes.io/name" = operator;
            };
          }
        ];
        toPorts = lib.toList {
          ports =
            map (port: {
              inherit port;
              protocol = "TCP";
            })
            ports;
        };
      };
    };

    policyFor = ns: c: let
      strict = strictApps ns;
      ports = upstreamPorts ns;
    in {
      description = "Default-deny ingress for ${ns}; baseline plus extraIngress only (nixidy/system/network/netpol.nix)";
      endpointSelector.matchExpressions =
        [
          {
            key = nsKey;
            operator = "In";
            values = [ns];
          }
        ]
        ++ lib.optional (strict != []) {
          key = "app.kubernetes.io/name";
          operator = "NotIn";
          values = strict;
        };
      ingress =
        [
          {fromEntities = ["host" "remote-node" "kube-apiserver"] ++ lib.optional c.gateway "ingress";}
        ]
        ++ lib.optional c.scrape {
          fromEndpoints = map (app: {
            matchLabels = {
              ${nsKey} = "observability";
              "app.kubernetes.io/name" = app;
            };
          }) ["prometheus" "gatus"];
        }
        ++ lib.optional c.intraNamespace {fromEndpoints = [{matchLabels.${nsKey} = ns;}];}
        ++ lib.optional (ports != []) {
          fromEndpoints = [
            {
              matchLabels = {
                ${nsKey} = "identity";
                "app.kubernetes.io/name" = "oauth2-proxy";
              };
            }
          ];
          toPorts = lib.toList {
            ports =
              map (port: {
                inherit port;
                protocol = "TCP";
              })
              ports;
          };
        }
        ++ c.extraIngress;
    };
  in {
    options.netpol.namespaces = lib.mkOption {
      description = "Per-namespace default-deny ingress";
      default = {};
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enforce = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Render the policy; until then the namespace stays open";
          };
          intraNamespace = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Let pods of the namespace reach each other (opt-in; apps with their own policy stay strict)";
          };
          gateway = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Let the Gateway's envoy reach the pods (HTTPRoute backends)";
          };
          scrape = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Let Prometheus and Gatus in `observability` reach the pods";
          };
          cnpg = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Namespace has CloudNativePG clusters: let the operator reach them";
          };
          dragonfly = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Namespace has Dragonfly instances: let the operator reach them";
          };
          extraIngress = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [];
            description = "More CiliumNetworkPolicy ingress rules (cross-namespace callers, external ports)";
          };
        };
      });
    };
    config.applications.netpol = lib.mkIf (enforced != {}) {
      namespace = "kube-system";
      resources.ciliumClusterwideNetworkPolicies = lib.mkMerge (lib.mapAttrsToList (ns: c: {
          "netpol-${ns}".spec = policyFor ns c;
          "netpol-${ns}-cnpg" = lib.mkIf c.cnpg {
            spec = operatorPolicy ns {
              key = "cnpg.io/cluster";
              operator = "Exists";
            } "cloudnative-pg" ["8000" "5432"];
          };
          "netpol-${ns}-dragonfly" = lib.mkIf c.dragonfly {
            spec = operatorPolicy ns {
              key = "app.kubernetes.io/name";
              operator = "In";
              values = ["dragonfly"];
              # 6379 for data, 9999 for the admin port the operator uses to verify
              # readiness and elect the master (without it no pod gets
              # role=master and the Service has no endpoints).
            } "dragonfly-operator" ["6379" "9999"];
          };
        })
        enforced);
    };
  };
}
