# Dashy portal: tiles from portal.apps, Keycloak login (public PKCE client).
# showForGroups hides tiles client-side only; oauth2-proxy enforces the same
# groups on the upstreams it fronts.
{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "dashy.${domain}";
in {
  nixidy = {
    charts,
    config,
    lib,
    pinned,
    pkgs,
    ...
  }: let
    yaml = pkgs.formats.yaml {};
    icon = i:
      if lib.any (p: lib.hasPrefix p i) ["http" "mdi-" "si-" "fa-" "hl-" "sh-"]
      then i
      else "hl-${i}";
    item = a:
      {
        inherit (a) title description url;
        icon = icon a.icon;
        target = "newtab";
      }
      // lib.optionalAttrs (a.groups != []) {displayData.showForGroups = a.groups;};
    # Palette from homepage's Dracula block.
    css = ''
      @import url('https://fonts.googleapis.com/css2?family=DM+Sans:opsz@9..40&display=swap');
      html[data-theme='dracula'] {
        --font-body: 'DM Sans', sans-serif;
        --font-headings: 'DM Sans', sans-serif;
        --primary: #bd93f9;
        --background: #282a36;
        --background-darker: #15161d;
        --item-background: #44475a46;
        --item-background-hover: #44475a91;
        --item-text-color: #f8f8f2;
        --description-tooltip-color: #bd93f9;
      }
    '';
    conf = {
      pageInfo = {
        title = "Homelab";
        navLinks = [
          {
            title = "Bookmarks";
            path = "/bookmarks.html";
          }
          {
            title = "Catalog";
            path = "/catalog.json";
          }
        ];
      };
      appConfig = {
        theme = "dracula";
        customCss = css;
        layout = "auto";
        iconSize = "medium";
        preventWriteToDisk = true;
        disableConfigurationForNonAdmin = true;
        enableServiceWorker = true;
        auth = {
          enableOidc = true;
          oidc = {
            clientId = "dashy";
            endpoint = "https://keycloak.${domain}/realms/default";
            scope = "openid profile email groups";
            adminGroup = "admin";
          };
        };
      };
      sections =
        lib.mapAttrsToList (name: apps: {
          inherit name;
          items = map item apps;
        })
        config.portal.sections;
    };
  in {
    gatus.endpoints.dashy = {
      url = "https://${hostname}";
      group = "internal";
    };
    portal.apps.dashy = {
      title = "Dashy";
      description = "Portal";
    };
    applications.keycloak.resources.keycloakClients.dashy.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "dashy";
        name = "Dashy";
        enabled = true;
        protocol = "openid-connect";
        publicClient = true;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        # Dashy redirects back to window.location.origin (no path).
        redirectUris = ["https://${hostname}" "https://${hostname}/*"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
        attributes."pkce.code.challenge.method" = "S256";
      };
    };
    applications.dashy = {
      namespace = "home";
      helm.releases.dashy = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.dashy = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.dashy = {
              image = pinned.images.dashy;
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.dashy.ports.http.port = 8080;
          # user-data is served as static files: conf.yml (stripped for
          # anonymous requests) plus the catalog exports.
          persistence.user-data = {
            type = "configMap";
            name = "dashy";
            globalMounts = lib.toList {path = "/app/user-data";};
          };
        };
      };
      # Outside the helm values: config.applications (read for tile sections)
      # depends on every release's rendered objects.
      resources.configMaps.dashy.data =
        config.portal.files
        // {"conf.yml" = builtins.readFile (yaml.generate "conf.yml" conf);};
      resources.httpRoutes.dashy.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "dashy";
            port = 8080;
          };
        };
      };
    };
  };
}
