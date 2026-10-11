# Hyprland plugins (hy3 tiling, hyprspace overview, hyprfocus) plus pyprland
# scratchpads/menus and hyprshade's scheduled screen shaders.
# hy3 and hyprspace are pinned (pkgs/{hy3,hyprspace}) to builds that match
# nixpkgs' Hyprland; hyprfocus is upstream's hyprland-plugins one (it absorbed
# the schradert/hyprfocus fork's flash/shrink idea; its `animatefocused`
# dispatcher is gone). Dropped: hyprshade's color-filter (no longer shipped).
{
  home = {
    config,
    lib,
    pinned,
    pkgs,
    ...
  }: let
    pinnedPlugin = name:
      pkgs.hyprlandPlugins.${name}.overrideAttrs {
        version = pinned.${name}.pin.version;
        src = pinned.${name};
      };
    pypr = lib.getExe' pkgs.pyprland "pypr";
    hyprshade = lib.getExe pkgs.hyprshade;
    session = "hyprland-session.target";
    workspaces = lib.range 1 12;
  in {
    config = lib.mkIf config.profiles.desktop.hyprland.enable {
      home.packages = [pkgs.pyprland pkgs.hyprshade];
      wayland.windowManager.hyprland = {
        plugins = [(pinnedPlugin "hy3") (pinnedPlugin "hyprspace") pkgs.hyprlandPlugins.hyprfocus];
        settings = {
          general.layout = "hy3";
          plugin.hy3 = {
            tabs.text_center = true;
            autotile.enable = true;
          };
          plugin.hyprfocus = {
            mode = "bounce";
            bounce_strength = 0.99;
          };
          exec = ["${hyprshade} auto"];
          workspace = ["special:exposed, gapsout:60, gapsin:30, bordersize:5, border:true, shadow:false"];
          bindn = [
            ", mouse_down, hy3:focustab, l, require_hovered"
            ", mouse_up, hy3:focustab, r, require_hovered"
          ];
          bind =
            [
              "$mod, Tab, overview:toggle, all"
              "$mod+SHIFT+CONTROL, Tab, exec, ${pypr} expose"
              "$mod+ALT, return, exec, ${pypr} toggle term"
              "$mod+ALT, v, exec, ${pypr} toggle volume"
              "$mod+ALT, m, exec, ${pypr} menu"

              "$mod, q, hy3:warpcursor"
              "$mod+SHIFT, q, hy3:killactive"
              "$mod, a, hy3:changefocus, raise"
              "$mod+SHIFT, a, hy3:changefocus, lower"
              "$mod, e, hy3:expand, expand"
              "$mod+SHIFT, e, hy3:expand, base"
              "$mod, d, hy3:makegroup, h"
              "$mod, s, hy3:makegroup, v"
              "$mod, z, hy3:makegroup, tab"
              "$mod, r, hy3:changegroup, opposite"
            ]
            ++ lib.concatLists (lib.mapAttrsToList (key: dir: [
                "$mod, ${key}, hy3:movefocus, ${dir}"
                "$mod+CONTROL, ${key}, hy3:movefocus, ${dir}, visible"
                "$mod+SHIFT, ${key}, hy3:movewindow, ${dir}, once"
                "$mod+SHIFT+CONTROL, ${key}, hy3:movewindow, ${dir}, once, visible"
              ]) {
                h = "l";
                j = "d";
                k = "u";
                l = "r";
              })
            ++ lib.concatMap (n: [
              "$mod, F${toString n}, workspace, ${toString n}"
              "$mod+SHIFT, F${toString n}, hy3:movetoworkspace, ${toString n}"
            ])
            workspaces;
        };
      };
      xdg.configFile."pypr/config.toml".source = (pkgs.formats.toml {}).generate "pyprland.toml" {
        pyprland.plugins = ["expose" "fetch_client_menu" "scratchpads" "shortcuts_menu" "system_notifier"];
        expose.include_special = true;
        scratchpads = lib.mapAttrs (_: sp:
          {
            size = "80% 85%";
            unfocus = "hide";
            preserve_aspect = true;
          }
          // sp) {
          term = {
            command = "wezterm start --class pypr-term";
            class = "pypr-term";
          };
          volume = {
            command = "pavucontrol";
            class = "org.pulseaudio.pavucontrol";
          };
        };
        shortcuts_menu.entries = {
          "Clipboard History" = [
            {
              name = "entry";
              command = "cliphist list";
              filter = "s/\\t.*//";
            }
            "cliphist decode '[entry]' | wl-copy"
          ];
          "Color Picker" = [
            {
              name = "format";
              options = ["hex" "rgb" "hsv" "hsl" "cmyk"];
            }
            "sleep 0.5; hyprpicker --format [format] | wl-copy"
          ];
          "Fetch Menu" = "pypr fetch_client_menu";
        };
        system_notifier.sources = [
          {
            command = "journalctl --follow --catalog --dmesg";
            parser = "journal";
          }
        ];
      };
      systemd.user.services.pyprland = {
        Unit.Description = "pyprland";
        Unit.After = [session];
        Unit.PartOf = [session];
        Service.ExecStart = pypr;
        Service.Restart = "on-failure";
        Install.WantedBy = [session];
      };
      xdg.configFile."hypr/hyprshade.toml".text = ''
        [[shades]]
        name = "vibrance"
        default = true

        [[shades]]
        name = "blue-light-filter"
        start_time = 18:00:00
        end_time = 06:00:00
      '';
      # What `hyprshade install` writes, declared; bound to the Hyprland session
      systemd.user.services.hyprshade = {
        Unit.Description = "Apply the scheduled screen shader";
        Service.Type = "oneshot";
        Service.ExecStart = "${hyprshade} auto";
      };
      systemd.user.timers.hyprshade = {
        Unit.PartOf = [session];
        Timer.OnCalendar = ["*-*-* 06:00:00" "*-*-* 18:00:00"];
        Install.WantedBy = [session];
      };
    };
  };
}
