# File and dev CLI utilities (+ nix-btm).
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs;
        [caligula docfd duf file localsend nix-btm openapi-tui ranger tran tree unzip xplr]
        ++ lib.optional stdenv.hostPlatform.isLinux udiskie;
    };
  };
}
