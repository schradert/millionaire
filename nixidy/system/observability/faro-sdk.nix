# Self-hosted Grafana Faro web SDK, for apps that take a custom script but are not built here (Forgejo,
# Homepage, Grafana's own frontend uses its bundled copy and needs none). Served at
# https://faro.trdos.me/sdk/<file> by a static nginx, no oauth2-proxy: the pages that load it are behind SSO, the
# bundle itself is public code. The version is pinned by the npm tarball's integrity hash and in the file name,
# so an upgrade is a new URL. Every embedding app registers itself in `faro.apps` (alloy.nix) and builds its
# script with `config.faro.snippet "<app name>"`.
{config, ...}: let
  inherit (config.canivete.meta) domain;
  faroHost = "faro.${domain}";
in {
  nixidy = {
    charts,
    config,
    lib,
    pinned,
    pkgs,
    ...
  }: let
    version = "2.12.1";
    file = "faro-web-sdk-${version}.iife.js";
    tarball = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@grafana/faro-web-sdk/-/faro-web-sdk-${version}.tgz";
      hash = "sha512-JnpZy/ztfkP3UZ3AW0DzUxVgMRTBvYz+m0oZuVi+KRpGTYz0GGF0umi0S0pAemnaUbQBo6umGdCm5CL6n8BAWQ==";
    };
    # The npm package's IIFE bundle (global GrafanaFaroWebSdk), minus the source map reference (not shipped).
    bundle = pkgs.runCommand file {} ''
      tar -xzOf ${tarball} package/dist/bundle/faro-web-sdk.iife.js | sed '/^\/\/# sourceMappingURL=/d' > $out
    '';
  in {
    options.faro.snippet = lib.mkOption {
      type = lib.types.functionTo lib.types.str;
      readOnly = true;
      internal = true;
      description = "JavaScript that loads the self-hosted SDK and starts Faro as the given `app.name` (a `faro.apps` name)";
    };
    config = {
      faro.snippet = app: ''
        (function () {
          var s = document.createElement("script");
          s.src = "https://${faroHost}/sdk/${file}";
          s.async = true;
          s.onload = function () {
            var f = window.GrafanaFaroWebSdk;
            f.initializeFaro({
              url: "https://${faroHost}/collect",
              app: { name: "${app}", environment: "production" },
              instrumentations: f.getWebInstrumentations({ captureConsole: true }),
            });
          };
          document.head.appendChild(s);
        })();
      '';
      # A GET of the bundle through the gateway proves the route and the file; the catalog gets no tile for it.
      gatus.endpoints.faro-sdk = {
        url = "https://${faroHost}/sdk/${file}";
        group = "internal";
      };
      portal.apps.faro-sdk.enable = false;
      applications.faro-sdk = {
        namespace = "observability";
        helm.releases.faro-sdk = {
          chart = charts.bjw-s-labs.app-template-patched;
          values = {
            controllers.faro-sdk = {
              annotations."reloader.stakater.com/auto" = "true";
              containers.nginx = {
                image = pinned.images.nginx;
                probes.liveness.enabled = true;
                probes.readiness.enabled = true;
                probes.startup.enabled = true;
              };
            };
            service.faro-sdk.ports.http.port = 80;
            configMaps.faro-sdk.data.${file} = builtins.readFile bundle;
            persistence.sdk = {
              type = "configMap";
              name = "faro-sdk";
              globalMounts = lib.toList {
                path = "/usr/share/nginx/html";
                readOnly = true;
              };
            };
          };
        };
        # /sdk/<file> -> /<file>; the receiver's own route (alloy.nix) takes /collect on the same host.
        resources.httpRoutes.faro-sdk.spec = {
          hostnames = [faroHost];
          parentRefs = lib.toList {
            name = "internal";
            namespace = "kube-system";
            sectionName = "https";
          };
          rules = lib.toList {
            matches = lib.toList {
              path = {
                type = "PathPrefix";
                value = "/sdk";
              };
            };
            filters = lib.toList {
              type = "URLRewrite";
              urlRewrite.path = {
                type = "ReplacePrefixMatch";
                replacePrefixMatch = "/";
              };
            };
            backendRefs = lib.toList {
              name = "faro-sdk";
              port = 80;
            };
          };
        };
      };
    };
  };
}
