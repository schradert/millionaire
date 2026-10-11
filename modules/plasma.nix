{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    ini = pkgs.formats.ini {};
  in {
    config = lib.mkMerge [
      (lib.mkIf config.profiles.desktop.plasma.enable {
        services.desktopManager.plasma6.enable = true;
        services.displayManager.sddm.enable = true;
        services.displayManager.sddm.wayland.enable = true;
        services.xserver.enable = true;
        home-manager.sharedModules = [
          {
            # Plasma rewrites ~/.gtkrc-2.0 which HM (stylix) also manages
            # NOTE https://github.com/nix-community/home-manager/issues/6188#issuecomment-2749859294
            gtk.gtk2.force = true;
            # TODO why isn't the builtin Plasma 6 notification daemon working?
            services.swaync.enable = true;
          }
        ];
      })
      (lib.mkIf config.profiles.desktop.plasma.mobile.enable {
        profiles.desktop.plasma.enable = true;
        services.displayManager.defaultSession = "plasma-mobile";
        services.displayManager.sessionPackages = [pkgs.kdePackages.plasma-mobile];
        hardware.sensor.iio.enable = true;
        environment.etc."xdg/kdeglobals".source = ini.generate "kdeglobals" {
          KDE.LookAndFeelPackage = "org.kde.plasma.phone";
        };
        environment.etc."xdg/kwinrc".source = ini.generate "kwinrc" {
          Wayland."InputMethod[$e]" = "/run/current-system/sw/share/applications/com.github.maliit.keyboard.desktop";
          Wayland.VirtualKeyboardEnabled = "true";
          "org.kde.kdecoration2".NoPlugin = "true";
        };
        environment.systemPackages = with pkgs.kdePackages;
          [
            plasma-mobile
            plasma-nano
            # Plasma Mobile Gear
            alligator
            angelfish
            audiotube
            calindori
            kalk
            kasts
            kclock
            keysmith
            koko
            krecorder
            ktrip
            kweather
            plasma-dialer
            spacebar
          ]
          ++ [pkgs.maliit-framework pkgs.maliit-keyboard];
      })
    ];
  };
}
