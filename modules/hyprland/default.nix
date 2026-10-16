# Hyprland as an alternate SDDM session beside Plasma (still the default
# session). Hyprland-only user services bind to hyprland-session.target so a
# Plasma login never starts them. Colors come from stylix.
# Dropped: hyprexpo + hyprwinwrap (not in nixpkgs for Hyprland 0.55),
# kitty, xwaylandvideobridge, the wpgtk border template, the extra square
# wallpaper widget on the lock screen (stylix.image is its background).
{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.desktop.hyprland.enable {
      programs.hyprland.enable = true;
      programs.hyprlock.enable = true;
      environment.sessionVariables.NIXOS_OZONE_WL = "1";
      xdg.portal.extraPortals = [pkgs.xdg-desktop-portal-gtk];
      xdg.portal.config.hyprland =
        {default = ["hyprland" "gtk"];}
        // lib.optionalAttrs config.profiles.desktop.plasma.enable {"org.freedesktop.impl.portal.FileChooser" = ["kde"];};
    };
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.profiles) nvidia;
    hyprctl = lib.getExe' pkgs.hyprland "hyprctl";
    loginctl = lib.getExe' pkgs.systemd "loginctl";
    systemctl = lib.getExe' pkgs.systemd "systemctl";
    pidof = lib.getExe' pkgs.procps "pidof";
    hyprlock = lib.getExe config.programs.hyprlock.package;
    brightnessctl = lib.getExe pkgs.brightnessctl;
  in {
    config = lib.mkIf config.profiles.desktop.hyprland.enable {
      home.packages = with pkgs; [
        hyprpicker
        qt6.qtwayland
        qt5.qtwayland
        # screenshots
        grim
        satty
        slurp
        swappy
        wl-screenrec
        # clipboard
        clipse
        wl-clipboard-rs
      ];
      services.cliphist.enable = true;
      services.wl-clip-persist.enable = true;
      services.hyprpolkitagent.enable = true;
      # Every wayland HM service follows this target; swaync stays on Plasma too
      wayland.systemd.target = "hyprland-session.target";
      systemd.user.services.swaync = lib.mkIf config.services.swaync.enable {
        Unit.PartOf = lib.mkForce ["graphical-session.target"];
        Unit.After = lib.mkForce ["graphical-session.target"];
        Install.WantedBy = lib.mkForce ["graphical-session.target"];
      };
      wayland.windowManager.hyprland = {
        enable = true;
        # NixOS programs.hyprland provides the package and portal
        package = null;
        portalPackage = null;
        configType = "hyprlang";
        systemd.variables = ["--all"];
        settings = {
          "$mod" = "SUPER";
          env = lib.optionals nvidia.enable ["LIBVA_DRIVER_NAME,nvidia" "__GLX_VENDOR_LIBRARY_NAME,nvidia" "NVD_BACKEND,direct"];
          cursor.no_hardware_cursors = lib.mkIf nvidia.enable 1;
          animations.enabled = 1;
          animations.animation = [
            "windows, 1, 4, default, slide"
            "border, 1, 5, default"
            "fade, 1, 5, default"
            "workspaces, 1, 3, default"
          ];
          bind = [
            "$mod, grave, exec, brave"
            "$mod, return, exec, wezterm"
            "$mod+SHIFT, return, exec, wezterm start -- emacs"
            "$mod, f, fullscreen"
            "$mod+CONTROL, f, togglefloating"
            "$mod+SHIFT, Escape, exec, ${loginctl} lock-session"
          ];
          bindm = [
            "$mod, mouse:272, movewindow"
            "$mod, mouse:273, resizewindow"
          ];
          decoration = {
            rounding = 8;
            active_opacity = 0.95;
            inactive_opacity = 0.83;
            blur.xray = true;
            shadow.range = 4;
          };
          general = {
            gaps_in = 6;
            gaps_out = 12;
            border_size = 4;
          };
          input.sensitivity = -1;
          input.touchpad.natural_scroll = true;
          misc.disable_hyprland_logo = true;
          misc.disable_splash_rendering = true;
        };
      };
      services.hypridle = {
        enable = true;
        settings = {
          general = {
            before_sleep_cmd = "${loginctl} lock-session";
            ignore_dbus_inhibit = true;
            # one hyprlock at a time
            lock_cmd = "${pidof} hyprlock || ${hyprlock}";
            # avoid pressing a key twice to wake the display
            after_sleep_cmd = "${hyprctl} dispatch dpms on";
          };
          listener = [
            {
              timeout = 150;
              on-timeout = "${brightnessctl} --save set 10";
              on-resume = "${brightnessctl} --restore";
            }
            {
              timeout = 300;
              on-timeout = "${loginctl} lock-session";
            }
            {
              timeout = 330;
              on-timeout = "${hyprctl} dispatch dpms off";
              on-resume = "${hyprctl} dispatch dpms on";
            }
            {
              timeout = 1800;
              on-timeout = "${systemctl} suspend";
            }
          ];
        };
      };
      programs.hyprlock = {
        enable = true;
        settings = {
          general.ignore_empty_input = true;
          input-field = {
            monitor = "";
            size = "200, 50";
            outline_thickness = 3;
            dots_size = 0.33;
            dots_spacing = 0.15;
            dots_center = true;
            fade_on_empty = true;
            placeholder_text = "<i>Password...</i>";
            rounding = -1;
            fail_text = "<i>$FAIL <b>($ATTEMPTS)</b></i>";
            position = "0, -20";
            halign = "center";
            valign = "center";
          };
          label = map (l:
            {
              monitor = "";
              position = "-100, ${l.y}";
              halign = "right";
              valign = "bottom";
              shadow_passes = 5;
              shadow_size = 10;
            }
            // removeAttrs l ["y"]) [
            {
              text = "cmd[update:1000] echo \"$TIME\"";
              font_size = 55;
              y = "70";
            }
            {
              text = "$USER";
              font_size = 20;
              y = "160";
            }
          ];
        };
      };
    };
  };
}
