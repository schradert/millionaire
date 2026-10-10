{
  nixos = {
    config,
    flake,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.client.enable {
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
    config = lib.mkIf config.profiles.client.enable {
      home.packages = with pkgs; [crosspipe pavucontrol qpwgraph wiremix];
    };
  };
}
