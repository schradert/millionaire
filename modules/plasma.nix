# Unported: the Plasma Mobile branch (gargoyle) in old/modules/nixos/plasma.nix.
{
  nixos = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.desktop.plasma.enable {
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
    };
  };
}
