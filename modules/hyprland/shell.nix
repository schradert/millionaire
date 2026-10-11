# Hyprland desktop shell: waybar (stylix-themed; replaces the AGS bar),
# swaync notifications, walker + elephant
# launcher with a power menu, and media/brightness keys.
# Unported: gauntlet (old/old/desktop/hyprland/gauntlet.nix; not in nixpkgs),
# AGS's wallpaper picker. The wallpaper is stylix.image via hyprpaper (stylix),
# which replaces the old swww daemon.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    session = "hyprland-session.target";
    onSession = {
      Unit.After = [session];
      Unit.PartOf = [session];
      Install.WantedBy = lib.mkForce [session];
    };
    wpctl = lib.getExe' pkgs.wireplumber "wpctl";
    playerctl = lib.getExe pkgs.playerctl;
    brightnessctl = lib.getExe pkgs.brightnessctl;
    walker = lib.getExe config.services.walker.package;
  in {
    config = lib.mkIf config.profiles.desktop.hyprland.enable {
      services.swaync.enable = true;
      services.elephant.enable = true;
      services.walker = {
        enable = true;
        systemd.enable = true;
      };
      systemd.user.services.elephant = onSession;
      systemd.user.services.walker = onSession;
      # not also tray.target, which a Plasma login can reach
      systemd.user.services.waybar = onSession;
      xdg.configFile."elephant/menus/power.toml".source = (pkgs.formats.toml {}).generate "power.toml" {
        name = "power";
        name_pretty = "Power";
        icon = "system-shutdown";
        entries =
          lib.mapAttrsToList (text: v: {
            inherit text;
            inherit (v) icon;
            actions.${text} = v.exec;
          }) {
            Shutdown = {
              icon = "system-shutdown";
              exec = "systemctl poweroff";
            };
            Reboot = {
              icon = "system-reboot";
              exec = "systemctl reboot";
            };
            Lock = {
              icon = "system-lock-screen";
              exec = "loginctl lock-session";
            };
          };
      };
      programs.waybar = {
        enable = true;
        systemd.enable = true;
        settings.main = {
          layer = "top";
          position = "left";
          margin = "5 2 5 0";
          reload_style_on_change = true;
          modules-left = ["hyprland/workspaces" "hyprland/submap" "mpris"];
          modules-center = ["hyprland/window"];
          modules-right = ["tray" "wireplumber" "clock"];
          "hyprland/submap".format = "<b>{}</b>";
          "hyprland/workspaces".all-outputs = false;
          "hyprland/window".rotate = 90;
          mpris.rotate = 90;
          clock.format = "{:%H\n%M}";
        };
      };
      wayland.windowManager.hyprland.settings = {
        bind = [
          "$mod, SPACE, exec, ${walker}"
          "$mod+SHIFT, SPACE, exec, ${walker} -m menus:power"
          "$mod, n, exec, ${lib.getExe' config.services.swaync.package "swaync-client"} -t -sw"
        ];
        # e: repeat while held, l: also on the lock screen
        bindel = [
          ", XF86AudioRaiseVolume, exec, ${wpctl} set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"
          ", XF86AudioLowerVolume, exec, ${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%-"
          ", XF86MonBrightnessUp, exec, ${brightnessctl} set 10%+"
          ", XF86MonBrightnessDown, exec, ${brightnessctl} set 10%-"
        ];
        bindl = [
          ", XF86AudioMute, exec, ${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle"
          ", XF86AudioMicMute, exec, ${wpctl} set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
          ", XF86AudioPlay, exec, ${playerctl} play-pause"
          ", XF86AudioPause, exec, ${playerctl} play-pause"
          ", XF86AudioNext, exec, ${playerctl} next"
          ", XF86AudioPrev, exec, ${playerctl} previous"
        ];
      };
    };
  };
}
