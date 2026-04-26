{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "home.${domain}";
in {
  nixidy = {
    charts,
    lib,
    pkgs,
    ...
  }: let
    yaml = pkgs.formats.yaml {};
    toYAML = name: obj: builtins.readFile (yaml.generate name obj);

    settings = {
      title = "Millionaire Homelab";
      color = "gray";
      theme = "dark";
      useEqualHeights = true;
      disableCollapse = false;
      headerStyle = "clean";
      background = {
        image = "https://images.unsplash.com/photo-1558618666-fcd25c85f82e?w=1920";
        blur = "sm";
        opacity = 50;
      };
      kubernetes = {
        mode = "cluster";
        gateway = true;
      };
    };

    services = [
      {
        "Finance" = [
          {
            "Firefly III" = {
              icon = "firefly-iii";
              href = "https://firefly.${domain}";
              description = "Personal finance manager";
            };
          }
          {
            "Actual Budget" = {
              icon = "actual";
              href = "https://actual.${domain}";
              description = "Zero-based budgeting";
            };
          }
          {
            "Sure" = {
              icon = "mdi-finance";
              href = "https://sure.${domain}";
              description = "Financial planning";
            };
          }
        ];
      }
      {
        "Health" = [
          {
            "Mealie" = {
              icon = "mealie";
              href = "https://mealie.${domain}";
              description = "Recipe manager";
            };
          }
        ];
      }
      {
        "Identity & Auth" = [
          {
            "Keycloak" = {
              icon = "keycloak";
              href = "https://keycloak.${domain}";
              description = "Identity & access management";
            };
          }
        ];
      }
      {
        "Infrastructure" = [
          {
            "ArgoCD" = {
              icon = "argocd";
              href = "https://argocd.${domain}";
              description = "GitOps continuous delivery";
            };
          }
          {
            "Grafana" = {
              icon = "grafana";
              href = "https://grafana.${domain}";
              description = "Monitoring dashboards";
            };
          }
          {
            "Prometheus" = {
              icon = "prometheus";
              href = "https://prometheus.${domain}";
              description = "Metrics collection";
            };
          }
          {
            "Alertmanager" = {
              icon = "alertmanager";
              href = "https://alertmanager.${domain}";
              description = "Alert routing";
            };
          }
          {
            "Gatus" = {
              icon = "gatus";
              href = "https://gatus.${domain}";
              description = "Uptime monitoring";
            };
          }
        ];
      }
    ];

    widgets = [
      {
        kubernetes = {
          cluster = {
            show = true;
            cpu = true;
            memory = true;
            showLabel = true;
            label = "millionaire";
          };
          nodes = {
            show = true;
            cpu = true;
            memory = true;
            showLabel = true;
          };
        };
      }
      {
        datetime = {
          text_size = "xl";
          format = {
            dateStyle = "long";
            timeStyle = "short";
          };
        };
      }
      {
        search = {
          provider = "google";
          target = "_blank";
        };
      }
    ];

    bookmarks = [
      {
        "Developer" = [
          {"GitHub" = [{icon = "github"; href = "https://github.com/schradert";}];}
          {"Nixpkgs" = [{icon = "nixos"; href = "https://search.nixos.org/packages";}];}
        ];
      }
    ];

    # Dracula theme CSS from https://github.com/Jas-SinghFSU/homepage-dracula
    draculaCSS = ''
      @import url('https://fonts.googleapis.com/css2?family=DM+Sans:opsz@9..40&family=Fira+Code&family=Poppins&family=Source+Code+Pro&family=Work+Sans&display=swap');

      .theme-gray {
        font-family: 'DM Sans', sans-serif;

        /* DRACULA COLORS */
        --dracula-background: #282a36;
        --dracula-background-dark: #15161d;
        --dracula-foreground: #44475a;
        --dracula-text: #f8f8f2;
        --dracula-slate: #6272a4;
        --dracula-cyan: #8be9fd;
        --dracula-green: #50fa7ae8;
        --dracula-orange: #ffb86c;
        --dracula-pink: #ff79c6;
        --dracula-purple: #bd93f9;
        --dracula-red: #ff5555;
        --dracula-yellow: #f1fa8c;

        /* Theme preset colors */
        --color-50: 249 250 251;
        --color-100: 243 244 246;
        --color-200: 248 248 242;
        --color-300: 209 213 219;
        --color-400: 156 163 175;
        --color-500: 107 114 128;
        --color-600: 75 85 99;
        --color-700: 55 65 81;
        --color-800: 40 42 54;
        --color-900: 21 22 29;
        --color-logo-start: 156 163 175;
        --color-logo-stop: 55 65 81;

        --standard-bg: #44475a8e;

        /* INFO WIDGET COLORS */
        --info-widgets: var(--dracula-purple);
        --resource-bar-bg: var(--standard-bg);
        --resource-bar-fg: var(--dracula-green);
        --widget-border: var(--dracula-foreground);

        /* SERVICES COLORS */
        --service-group: var(--dracula-purple);
        --service-name: var(--dracula-text);
        --service-description: var(--dracula-purple);
        --service-block-bg: #232530;
        --service-block-text: var(--dracula-pink);

        /* BOOKMARKS COLORS */
        --bookmark-group: var(--dracula-purple);
        --bookmark-icon-bg: #44475a60;
        --bookmark-icon: var(--dracula-purple);
        --bookmark-name: var(--dracula-text);

        /* ALL CARD COLORS */
        --card-color: #44475a46;
        --card-color-hover: #44475a91;

        /* FOOTER COLORS */
        --footer-items: var(--dracula-pink);

        /* SCROLLBAR COLORS */
        --scrollbar-fg: var(--dracula-purple);
        --scrollbar-bg: var(--standard-bg);

        .service-tags .dark\:bg-theme-900\/50 {
          background-color: rgb(var(--color-900) / 0.3) !important;
        }

        /* INFORMATION WIDGETS STYLES */
        #information-widgets { border-color: var(--widget-border); }
        #information-widgets * { color: var(--info-widgets); }
        .resource-usage { background-color: var(--resource-bar-bg); }
        .resource-usage > div { background-color: var(--resource-bar-fg); }

        /* SERVICES STYLES */
        .service-group-icon > div { background: var(--service-group) !important; }
        .service-group-name { color: var(--service-group) !important; }
        .services-group > button > svg { color: var(--service-group); }
        .service-card { background-color: var(--card-color); }
        .service-card:hover { background-color: var(--card-color-hover); }
        .service-name.text-sm { font-size: 0.95rem; color: var(--service-name); }
        .service-description.text-xs { font-size: 0.75rem; color: var(--service-description); }
        .service img { border-radius: 25%; }
        .service-block { background: var(--service-block-bg); }
        .service-block .uppercase { color: var(--service-block-text); }
        .service-block .font-thin { color: var(--dracula-text); }

        /* BOOKMARK STYLES */
        .bookmark-group-name { color: var(--bookmark-group) !important; }
        .bookmark-icon { background-color: var(--bookmark-icon-bg) !important; }
        .bookmark-icon > div > div { background: var(--bookmark-icon) !important; }
        .bookmark-name.text-xs { font-size: 0.85rem; color: var(--bookmark-name); }
        li.bookmark > a { background-color: var(--card-color); }
        li.bookmark > a:hover { background-color: var(--card-color-hover); }

        /* CALENDAR STYLES */
        #dracula-calendar .flex.justify-between.flex-wrap span { color: var(--dracula-purple); }

        /* FOOTER STYLES */
        #footer svg { color: var(--footer-items); }

        /* SCROLLBAR STYLES */
        * {
          --scrollbar-thumb: var(--scrollbar-fg);
          --scrollbar-track: var(--scrollbar-bg);
        }

        /* GLANCES STYLES */
        li[id^='glances-'] .recharts-surface > g:nth-of-type(1) path:nth-child(1) { fill: var(--dracula-green); fill-opacity: 0.15; }
        li[id^='glances-'] .recharts-surface g:nth-of-type(1) path:nth-child(2) { stroke: var(--dracula-green); stroke-opacity: 0.5; }
        li[id^='glances-'] .recharts-surface g:nth-of-type(2) path:nth-child(1) { fill: var(--dracula-purple); fill-opacity: 0.15; }
        li[id^='glances-'] .recharts-surface g:nth-of-type(2) path:nth-child(2) { stroke: var(--dracula-purple); stroke-opacity: 0.5; }
        li[id^='glances-'] .bottom-3.left-3 { color: var(--dracula-pink); }
        li[id^='glances-'] .bottom-3.right-3 .opacity-75 { color: var(--dracula-cyan); opacity: 1; font-size: 0.8rem; }
        li[id^='glances-'] .top-3.right-3 .opacity-50 { color: var(--dracula-cyan); opacity: 1; font-size: 0.8rem; }
        li[id^='glances-'] .opacity-50 { opacity: 0.8; }
        li[id^='glances-'] .flex.items-center.text-xs .text-right { color: var(--dracula-cyan); }
        li[id^='glances-'] .flex.items-center .opacity-25.w-14.text-right { color: var(--dracula-purple); opacity: 0.85; }
        li[id^='glances-'] .bottom-4.right-3.left-3.z-20 .w-3.h-3.mr-1\.5.opacity-50 > div { background: var(--dracula-green) !important; opacity: 1; }
        li[id^='glances-'] .bottom-4.right-3.left-3.z-20 .opacity-75.grow { color: var(--dracula-pink) !important; opacity: 0.75; }

        /* HOMEPAGE COLOR PRESETS */
        .bg-amber-500 { background-color: var(--dracula-orange); }
        .bg-blue-500 { background-color: var(--dracula-cyan); }
        .bg-cyan-500 { background-color: var(--dracula-cyan); }
        .bg-emerald-500 { background-color: var(--dracula-green); }
        .bg-fuchsia-500 { background-color: var(--dracula-pink); }
        .bg-gray-500 { background-color: var(--dracula-foreground); }
        .bg-green-500 { background-color: var(--dracula-green); }
        .bg-indigo-500 { background-color: var(--dracula-purple); }
        .bg-lime-500 { background-color: var(--dracula-green); }
        .bg-orange-400 { background-color: var(--dracula-orange); }
        .bg-orange-500 { background-color: var(--dracula-orange); }
        .bg-pink-500 { background-color: var(--dracula-pink); }
        .bg-purple-500 { background-color: var(--dracula-purple); }
        .bg-red-500 { background-color: var(--dracula-red); }
        .bg-rose-500 { background-color: var(--dracula-red); }
        .bg-rose-900\/80 { background-color: var(--dracula-red); }
        .bg-sky-500 { background-color: var(--dracula-cyan); }
        .bg-slate-500 { background-color: var(--dracula-slate); }
        .bg-violet-500 { background-color: var(--dracula-purple); }
        .bg-white { background-color: var(--dracula-text); }
        .bg-yellow-500 { background-color: var(--dracula-yellow); }
        .text-emerald-300 { color: var(--dracula-green); }
        .text-green-500 { color: var(--dracula-green); }
        .text-red-400 { color: var(--dracula-red); }
        .text-red-500 { color: var(--dracula-red); }
        .text-rose-300 { color: var(--dracula-red); }
        .text-rose-500 { color: var(--dracula-red); }
        .text-white { color: var(--dracula-text); }
      }
    '';
  in {
    gatus.endpoints.homepage = {url = "https://${hostname}"; group = "internal";};
    applications.homepage = {
      namespace = "home";
      helm.releases.homepage = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.homepage = {
            containers.homepage = {
              image.repository = "ghcr.io/gethomepage/homepage";
              image.tag = "v1.2.0";
              env.HOMEPAGE_ALLOWED_HOSTS = hostname;
              ports = lib.toList {name = "http"; containerPort = 3000;};
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/api/healthcheck";
                spec.httpGet.port = "http";
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/api/healthcheck";
                spec.httpGet.port = "http";
              };
              probes.startup.enabled = true;
            };
            pod.serviceAccountName = "homepage";
          };
          service.homepage.ports.http.port = 3000;
          serviceAccount.homepage.create = true;
          configMaps.homepage.data = {
            "settings.yaml" = toYAML "settings.yaml" settings;
            "services.yaml" = toYAML "services.yaml" services;
            "widgets.yaml" = toYAML "widgets.yaml" widgets;
            "bookmarks.yaml" = toYAML "bookmarks.yaml" bookmarks;
            "kubernetes.yaml" = toYAML "kubernetes.yaml" {mode = "cluster"; gateway = true;};
            "custom.css" = draculaCSS;
            "custom.js" = "";
            "docker.yaml" = "";
          };
          persistence.config = {
            type = "configMap";
            name = "homepage";
            globalMounts = lib.toList {path = "/app/config";};
          };
        };
      };

      resources.clusterRoles.homepage-discovery.rules = [
        {apiGroups = [""]; resources = ["namespaces" "pods" "nodes"]; verbs = ["get" "list"];}
        {apiGroups = ["networking.k8s.io"]; resources = ["ingresses"]; verbs = ["get" "list"];}
        {apiGroups = ["gateway.networking.k8s.io"]; resources = ["httproutes" "gateways"]; verbs = ["get" "list"];}
        {apiGroups = ["metrics.k8s.io"]; resources = ["nodes" "pods"]; verbs = ["get" "list"];}
      ];
      resources.clusterRoleBindings.homepage-discovery = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "homepage-discovery";
        };
        subjects = lib.toList {
          kind = "ServiceAccount";
          name = "homepage";
          namespace = "home";
        };
      };

      resources.httpRoutes.homepage.spec = {
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
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://homepage.home.svc.cluster.local:3000";
      namespace = "home";
    };
  };
}
