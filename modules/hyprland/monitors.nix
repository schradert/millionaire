# Per-host Hyprland monitor layout (static/<host>.nix): monitors keyed by
# Hyprland's `desc:` (make model serial), positions in physical pixels so they
# hold at any scale, and an optional zoom scale toggled with $mod+SHIFT+z.
{
  shared = {
    can,
    lib,
    ...
  }: {
    options.profiles.desktop.hyprland = {
      monitors = can.attrs.submodule "Hyprland monitors by description" {
        options = {
          mode = can.str "resolution@refresh" {default = "preferred";};
          position = can.list.int "top-left corner in physical pixels" {default = [0 0];};
          transform = can.int "wl_output transform (1 = 90°)" {default = 0;};
          workspaces = can.list.int "workspaces bound to this monitor" {};
        };
      };
      scale = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "scale of every listed monitor";
      };
      zoomScale = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        description = "alternate scale toggled with $mod+SHIFT+z";
      };
    };
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.profiles.desktop.hyprland;
    lines = scale:
      lib.mapAttrsToList (desc: m: let
        pos = map (p: toString (builtins.floor (p / scale))) m.position;
      in
        "desc:${desc}, ${m.mode}, ${lib.concatStringsSep "x" pos}, ${toString scale}"
        + lib.optionalString (m.transform != 0) ", transform, ${toString m.transform}")
      cfg.monitors;
    batch = scale: lib.concatMapStringsSep " ; " (l: "keyword monitor ${l}") (lines scale);
    toggle = pkgs.writeShellApplication {
      name = "hyprland-zoom";
      runtimeInputs = [pkgs.hyprland pkgs.jq];
      text = ''
        if hyprctl -j monitors | jq -e '.[0].scale == ${toString cfg.scale}' >/dev/null; then
          hyprctl --batch ${lib.escapeShellArg (batch cfg.zoomScale)}
        else
          hyprctl --batch ${lib.escapeShellArg (batch cfg.scale)}
        fi
      '';
    };
  in {
    config = lib.mkIf (cfg.enable && cfg.monitors != {}) {
      wayland.windowManager.hyprland.settings = {
        monitor = lines cfg.scale;
        workspace = lib.concatLists (lib.mapAttrsToList (desc: m: map (n: "${toString n}, monitor:desc:${desc}") m.workspaces) cfg.monitors);
        bind = lib.optional (cfg.zoomScale != null) "$mod+SHIFT, z, exec, ${lib.getExe toggle}";
      };
    };
  };
}
