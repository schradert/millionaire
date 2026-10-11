{
  nixos = {
    config,
    flake,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.client.enable {
      hardware.bluetooth.enable = true;
      security.rtkit.enable = true;
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        jack.enable = true;
      };
      users.users.${flake.config.canivete.meta.people.me}.extraGroups = ["audio"];
    };
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.profiles.client.enable && pkgs.stdenv.hostPlatform.isLinux) {
      home.packages = with pkgs; [asak crosspipe pavucontrol playerctl qpwgraph wiremix];
      # MPRIS: playerctl follows the most recently active player.
      services.playerctld.enable = true;
    };
  };
}
