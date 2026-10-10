# Launcher catalog: every app registers a tile once, and each portal (dashy,
# homepage, homarr) plus the bookmark exports render it. Every gatus endpoint
# seeds a tile (mkDefault), so apps only set what differs: icon, groups, ….
{can, ...}: {
  nixidy = {
    config,
    lib,
    ...
  }: let
    cfg = config.portal;
    origin = url: lib.head (builtins.match "(https?://[^/]+).*" url);
    # host -> namespace of the application whose HTTPRoute serves it
    routeNamespaces = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (_: app:
      lib.concatMap (route: map (host: lib.nameValuePair host app.namespace) (route.spec.hostnames or []))
      (lib.attrValues (app.resources.httpRoutes or {})))
    config.applications));
    namespaceOf = name: url:
      routeNamespaces.${lib.removePrefix "https://" (origin url)}
      or config.applications.${name}.namespace or "other";
    sectionNames = {
      ai = "AI";
      cicd = "CI/CD";
    };
    sectionOf = ns: sectionNames.${ns} or (lib.toUpper (lib.substring 0 1 ns) + lib.substring 1 (-1) ns);
    iconUrl = icon:
      if lib.hasPrefix "http" icon
      then icon
      else if lib.hasPrefix "mdi-" icon
      then "https://cdn.jsdelivr.net/npm/@mdi/svg/svg/${lib.removePrefix "mdi-" icon}.svg"
      else "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/${icon}.svg";
    catalog = lib.sortOn (a: [a.section a.title]) (lib.mapAttrsToList (name: a: {
      inherit name;
      inherit (a) title url icon section description groups;
      iconUrl = iconUrl a.icon;
    }) (lib.filterAttrs (_: a: a.enable) cfg.apps));
    sections = lib.groupBy (a: a.section) catalog;
    esc = lib.escapeXML;
    bookmarks = ''
      <!DOCTYPE NETSCAPE-Bookmark-file-1>
      <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
      <TITLE>Bookmarks</TITLE>
      <H1>Bookmarks</H1>
      <DL><p>
        <DT><H3>Homelab</H3>
        <DL><p>
      ${lib.concatStrings (lib.mapAttrsToList (section: apps: ''
            <DT><H3>${esc section}</H3>
            <DL><p>
          ${lib.concatMapStrings (a: "      <DT><A HREF=\"${esc a.url}\" ICON_URI=\"${esc a.iconUrl}\">${esc a.title}</A>\n") apps}    </DL><p>
        '')
        sections)}  </DL><p>
      </DL><p>
    '';
  in {
    options.portal = {
      apps = can.attrs.submodule "Launcher tiles each app registers" ({name, ...}: {
        options.enable = can.bool "Show this tile" {default = true;};
        options.title = can.str "Display name" {default = name;};
        options.url = can.str "Launch URL" {};
        options.icon = can.str "dashboard-icons slug, mdi-<name> or an image URL" {default = name;};
        options.section = can.str "Section heading" {};
        options.description = can.str "One-liner" {default = "";};
        options.groups = can.list.str "Keycloak groups allowed (any of); empty = every signed-in user" {default = [];};
      });
      catalog = can.list.raw "Enabled tiles, sorted by section and title" {internal = true;};
      sections = can.attrs.raw "Enabled tiles grouped by section" {internal = true;};
      files = can.attrs.str "Catalog exports: catalog.json, bookmarks.html" {internal = true;};
    };
    config.portal = {
      apps = lib.mkMerge [
        (lib.mapAttrs (name: ep: {
          url = lib.mkDefault (origin ep.url);
          section = lib.mkDefault (sectionOf (namespaceOf name ep.url));
        }) (lib.filterAttrs (_: ep: lib.hasPrefix "http" ep.url) config.gatus.endpoints))
        # The sign-in endpoint, not an app.
        {oauth2-proxy.enable = false;}
      ];
      inherit catalog sections;
      files = {
        "catalog.json" = builtins.toJSON catalog;
        "bookmarks.html" = bookmarks;
      };
    };
  };
}
